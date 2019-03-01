require 'forwardable'
require_relative 'gym_experiment'
require_relative 'observation_compressor'
require_relative 'atari_wrapper'
require_relative 'tools'

module DNE
  # TODO: why doesn't it work when I use UInt8? We're in [0,255]!
  NImage = Xumo::UInt32 # set a single data type for images

  # Specialized GymExperiment class for Atari environments and UL-ERL.
  class AtariUlerlExperiment < GymExperiment

    attr_reader :compr, :resize, :preproc, :nobs_per_ind, :ntrials_per_ind

    def initialize config
      ## Why would I wish:
      # compr before super (current choice)
      # - net.struct => compr.code_size
      # super before compr
      # - config[:run][:debug] # can live without
      # - compr.dims => AtariWrapper.downsample # gonna duplicate the process, beware
      # - obs size => AtariWrapper orig_size
      puts "Initializing compressor" # if debug
      compr_opts = config.delete :compr # otherwise unavailable for debug
      seed_proport = compr_opts.delete :seed_proport
      @nobs_per_ind = compr_opts.delete :nobs_per_ind
      @preproc = compr_opts.delete :preproc
      @ntrials_per_ind = config[:run].delete :ntrials_per_ind
      @compr = ObservationCompressor.new **compr_opts
      # default ninputs for network
      config[:net][:ninputs] ||= compr.code_size
      puts "Loading Atari OpenAI Gym environment" # if debug
      super config
      # initialize the centroids based on the env's reset obs
      compr.reset_centrs single_env.reset_obs, proport: seed_proport if seed_proport
    end

    # Initializes the Atari environment
    # @note python environments interfaced through pycall
    # @param type [String] the type of environment as understood by OpenAI Gym
    # @param [Array<Integer,Integer>] optional downsampling for rows and columns
    # @return an initialized environment


    # NEW ENVS CURRENTLY SPAWNED IN PARALL CHILD
    # means that they'll get respawned every time
    # should instead update @parall_env in parent after every pop
    # for now keep like this, spawning is fast and gets deleted with child process
    # we are ensuring there's one per ind and that's what matters
    # note the same env is used for multiple evals on each ind
    def init_env type:
      # puts "  initializing env" if debug
      # print "(newenv) " #if debug
      AtariWrapper.new gym.make(type), downsample: compr.downsample,
        skip_type: skip_type, preproc: preproc
    end

    # How to aggregate observations coming from a sequence of noops
    OBS_AGGR = {
      avg: -> (obs_lst) { obs_lst.reduce(:+) / obs_lst.size},
      new: -> (obs_lst) { obs_lst.first - env.reset_obs},
      first: -> (obs_lst) { obs_lst.first },
      last: -> (obs_lst) { obs_lst.last }
    }

    # Return the fitness of a single genotype
    # @param genotype the individual to be evaluated
    # @param env the environment to use for the evaluation
    # @param render [bool] whether to render the evaluation on screen
    # @param nsteps [Integer] how many interactions to run with the game. One interaction is one action choosing + enacting followed by `skip_frames` frame skips
    def fitness_one genotype, env: single_env, render: false, nsteps: max_nsteps, aggr_type: :last
      puts "Evaluating one individual" if debug
      puts "  Loading weights in network" if debug
      net.deep_reset
      net.load_weights genotype
      observation = env.reset
      # require 'pry'; binding.pry unless observation == env.reset_obs # => check passed, add to tests
      env.render if render
      tot_reward = 0
      # # set of observations with highest novelty, representative of the ability of the individual
      # # to obtain novel observations from the environment => hence reaching novel env states
      # represent_obs = []

      puts "IGNORING `nobs_per_ind=#{nobs_per_ind}` (random sampling obs)" if nobs_per_ind
      represent_obs = observation
      nobs = 1

      puts "  Running (max_nsteps: #{max_nsteps})" if debug
      runtime = nsteps.times do |i|
        code = compr.encode observation
        # print code.to_a
        selected_action = action_for code
        obs_lst, rew, done, info_lst = env.execute selected_action, skip_frames: skip_frames
        # puts "#{obs_lst}, #{rew}, #{done}, #{info_lst}" if debug
        observation = OBS_AGGR[aggr_type].call obs_lst
        tot_reward += rew
        ## NOTE: SWAP COMMENTS ON THE FOLLOWING to switch to novelty-based obs selection
        # # The same observation represents the state both for action selection and for individual novelty
        # # OPT: most obs will most likely have lower novelty, so place it first
        # # TODO: I could add here a check if obs is already in represent_obs; in fact
        # #       though the probability is low (sequential markovian fully-observable env)
        # novelty = compr.novelty observation, code
        # represent_obs.unshift [observation, novelty]
        # represent_obs.sort_by! &:last
        # represent_obs.shift if represent_obs.size > nobs_per_ind

        # Random sampling for representative obs
        nobs += 1
        represent_obs = observation if rand < 1.0/nobs

        # Image selection by random sampling

        env.render if render
        break i if done
      end
      compr.train_set << represent_obs
      # for novelty:
      # represent_obs.each { |obs, _nov| compr.train_set << obs }
      puts "=> Done! fitness: #{tot_reward}" if debug
      # print tot_reward, ' ' # if debug
      print "#{tot_reward}(#{runtime}) "
      tot_reward
    end

    # Builds a function that return a list of fitnesses for a list of genotypes.
    # Since Parallel runs in separate fork, this overload is needed to fetch out
    # the training set before returning the fitness to the optimizer
    # @param type the type of computation
    # @return [lambda] function that evaluates the fitness of a list of genotype
    # @note returned function has param genotypes [Array<gtype>] list of genotypes, return [Array<Numeric>] list of fitnesses for each genotype
    def gen_fit_fn type, ntrials: ntrials_per_ind
      return super unless type.nil? || type == :parallel
      nprocs = Parallel.processor_count - 1 # it's actually faster this way
      puts "Running in parallel on #{nprocs} processes"
      -> (genotypes) do
        print "Fits: "
        fits, parall_infos = Parallel.map(0...genotypes.shape.first,
            in_processes: nprocs, isolation: true) do |i|
          # env = parall_envs[Parallel.worker_number]
          env = parall_envs[i] # leveraging dynamic env allocation
          # fit = fitness_one genotypes[i, true], env: env
          fits = ntrials.times.map { fitness_one genotypes[i, true], env: env }
          fit = fits.to_na.mean
          print "[m#{fit}] "
          [fit, compr.parall_info]
        end.transpose
        puts # newline here because I'm done `print`ing all ind fits
        puts "Exporting training images"
        parall_infos.each &compr.method(:add_from_parall_info)
        puts "Training optimizer"
        fits.to_na
      end
    end

    # Return an action for an encoded observation
    # The neural network is activated on the code, then its output is
    # interpreted as a corresponding action
    # @param code [Array] encoding for the current observation
    # @return [Integer] action
    # TODO: alternatives like softmax and such
    def action_for code
      output = net.activate code
      nans = output.isnan
      # this is a pretty reliable bug indicator
      raise "\n\n\tNaN network output!!\n\n" if nans.any?
      # action = output[0...6].max_index # limit to 6 actions
      action = output.max_index
    end

    def update_opt
      return false if @curr_ninputs == compr.code_size
      puts "  code_size: #{compr.code_size}"
      diff = compr.code_size - @curr_ninputs
      @curr_ninputs = compr.code_size
      pl = net.struct.first(2).reduce(:*)
      nw = diff * net.struct[1]

      new_mu_val = 0     # value for the new means (0)
      new_var_val = 0.0001  # value for the new variances (diagonal of covariance) (<<1)
      new_cov_val = 0    # value for the other covariances (outside diagonal) (0)

      old = case opt_type
      when :XNES  then opt
      when :BDNES then opt.blocks.first
      else raise NotImplementedError, "refactor and fill in this case block"
      end

      new_mu = old.mu.insert pl, [new_mu_val]*nw
      new_sigma = old.sigma.insert [pl]*nw, new_cov_val, axis: 0
      new_sigma = new_sigma.insert [pl]*nw, new_cov_val, axis: 1
      new_sigma.diagonal[pl...(pl+nw)] = new_var_val

      new_nes = NES::XNES.new new_mu.size, old.obj_fn, old.opt_type,
        parallel_fit: old.parallel_fit, mu_init: new_mu, sigma_init: new_sigma,
        **opt_opt
      new_nes.instance_variable_set :@rng, old.rng   # ensure rng continuity
      new_nes.instance_variable_set :@best, old.best # ensure best continuity

      case opt_type
      when :XNES
        @opt = new_nes
        puts "  new opt dims: #{opt.ndims}"
      when :BDNES
        opt.blocks[0] = new_nes
        opt.ndims_lst[0] = new_mu.size
        puts "  new opt dims: #{opt.ndims_lst}"
      else raise NotImplementedError, "refactor and fill in this case block"
      end

      puts "  popsize: #{opt.popsize}"
      puts "  lrate: #{opt.lrate}"

      # FIXME: I need to run these before I can use automatic popsize again!
      # => update popsize in bdnes and its blocks before using it again
      # if opt.kind_of? BDNES or something
      # opt.instance_variable_set :popsize, blocks.map(&:popsize).max
      # opt.blocks.each { |xnes| xnes.instance_variable_set :@popsize, opt.popsize }

      # update net, since inputs have changed
      @net = init_net netopts.merge({ninputs: compr.code_size})
      puts "  new net struct: #{net.struct}"
      return true
    end

    # Run the experiment
    def run ngens: max_ngens
      @curr_ninputs = compr.code_size
      ngens.times do |i|
        $ngen = i # allows for conditional debugger calls `binding.pry if $ngen = n`
        puts Time.now
        puts "# Gen #{i+1}/#{ngens}"
        # it just makes more sense run first, even though at first gen the trainset is empty
        puts "Training compressor" if debug

        compr.train
        update_opt  # if I have more centroids, I should update opt

        opt.train
        # Note: data analysis is done by extracting statistics from logs using regexes.
        # Just `puts` anything you'd like to track, and save log to file
        puts "Best fit so far: #{opt.best.first} -- " \
             "Fit mean: #{opt.last_fits.mean} -- " \
             "Fit stddev: #{opt.last_fits.stddev}\n" \
             "Mu mean: #{opt.mu.mean} -- " \
             "Mu stddev: #{opt.mu.stddev} -- " \
             "Conv: #{opt.convergence}"

        break if termination_criteria&.call(opt) # uhm currently unused
      end
    end

    # Save experiment current state to file
    def dump fname="dumps/atari_#{Time.now.strftime '%y%m%d_%H%M'}.bin"
      raise NotImplementedError, "doesn't work with BDNES atm" if config[:opt][:type] == :BDNES
      File.open(fname, 'wb') do |f|
        Marshal.dump(
          { config: config,
            best: opt.best.last,
            mu: opt.mu,
            sigma: opt.sigma,
            centrs: compr.centrs
          }, f)
      end
      puts "Experiment data dumped to `#{fname}`"
      true
    end

    # Load experiment state from file
    def load fname=Dir["dumps/atari_*.bin"].sort.last
      hsh = File.open(fname, 'r') { |f| Marshal.load f }
      initialize hsh[:config]
      opt.instance_variable_set :@best, hsh[:best]
      opt.instance_variable_set :@mu, hsh[:mu]
      opt.instance_variable_set :@sigma, hsh[:sigma]
      compr.instance_variable_set :@centrs, hsh[:centrs]
      # Uhm haven't used that yet...
      # what else needs to be done in order to be able to run `#show_ind` again?
      puts "Experiment data loaded from `#{fname}`"
      true
    end

    # Return an initialized exp from state on file
    def self.load fname=Dir["atari_*.bin"].sort.last
      # will initialize twice, but we're sure to have a conform `hsh[:config]`
      hsh = File.open(fname, 'r') { |f| Marshal.load f }
      new(hsh[:config]).tap { |exp| exp.load fname }
    end

  end
end

puts "USAGE: `bundle exec ruby experiments/atari.rb`" if __FILE__ == $0
