require 'open3'
module Hydra #:nodoc:
  # Hydra Task Common attributes and methods
  class Task
    # Name of the task. Default 'hydra'
    attr_accessor :name

    # Files to test.
    # You can add files manually via:
    #   t.files << [file1, file2, etc]
    #
    # Or you can use the add_files method
    attr_accessor :files

    # True if you want to see Hydra's message traces
    attr_accessor :verbose

    # Path to the hydra config file.
    # If not set, it will check 'hydra.yml' and 'config/hydra.yml'
    attr_accessor :config

    # Automatically sort files using their historical runtimes.
    # Defaults to true
    # To disable:
    #   t.autosort = false
    attr_accessor :autosort

    # Event listeners. Defaults to the MinimalOutput listener.
    # You can add additional listeners if you'd like. For example,
    # on linux (with notify-send) you can add the notifier listener:
    #   t.listeners << Hydra::Listener::Notifier.new
    attr_accessor :listeners

    #
    # Search for the hydra config file
    def find_config_file
      @config ||= 'hydra.yml'
      return @config if File.exists?(@config)
      @config = File.join('config', 'hydra.yml')
      return @config if File.exists?(@config)
      @config = nil
    end
    
    # Add files to test by passing in a string to be run through Dir.glob.
    # For example:
    #
    #   t.add_files 'test/units/*.rb'
    def add_files(pattern)
      @files += Dir.glob(pattern)
    end

  end

  # Define a test task that uses hydra to test the files.
  #
  #   Hydra::TestTask.new('hydra') do |t|
  #     t.add_files 'test/unit/**/*_test.rb'
  #     t.add_files 'test/functional/**/*_test.rb'
  #     t.add_files 'test/integration/**/*_test.rb'
  #     t.verbose = false # optionally set to true for lots of debug messages
  #     t.autosort = false # disable automatic sorting based on runtime of tests
  #   end  
  class TestTask < Hydra::Task

    # Create a new HydraTestTask
    def initialize(name = :hydra)
      @name = name
      @files = []
      @verbose = false
      @autosort = true
      @listeners = [Hydra::Listener::ProgressBar.new]

      yield self if block_given?

      # Ensure we override rspec's at_exit
      require 'hydra/spec/autorun_override'

      @config = find_config_file

      @opts = {
        :verbose => @verbose,
        :autosort => @autosort,
        :files => @files,
        :listeners => @listeners
      }
      if @config
        @opts.merge!(:config => @config)
      else
        @opts.merge!(:workers => [{:type => :local, :runners => 1}])
      end

      define
    end

    private
    # Create the rake task defined by this HydraTestTask
    def define
      desc "Hydra Tests" + (@name == :hydra ? "" : " for #{@name}")
      task @name do
        Hydra::Master.new(@opts)
        #exit(0) #bypass test on_exit output
      end
    end
  end

  # Define a sync task that uses hydra to rsync the source tree under test to remote workers.
  #
  # This task is very useful to run before a remote db:reset task to make sure the db/schema.rb
  # file is up to date on the remote workers.
  #
  #   Hydra::SyncTask.new('hydra:sync') do |t|
  #     t.verbose = false # optionally set to true for lots of debug messages
  #   end  
  class SyncTask < Hydra::Task

    # Create a new SyncTestTask
    def initialize(name = :sync)
      @name = name
      @verbose = false

      yield self if block_given?

      @config = find_config_file

      @opts = {
        :verbose => @verbose
      }
      @opts.merge!(:config => @config) if @config

      define
    end

    private
    # Create the rake task defined by this HydraSyncTask
    def define
      desc "Hydra Tests" + (@name == :hydra ? "" : " for #{@name}")
      task @name do
        Hydra::Sync.sync_many(@opts)
      end
    end
  end

  # Setup a task that will be run across all remote workers
  #   Hydra::RemoteTask.new('db:reset')
  #
  # Then you can run:
  #   rake hydra:remote:db:reset
  class RemoteTask < Hydra::Task
    include Open3
    # Create a new hydra remote task with the given name.
    # The task will be named hydra:remote:<name>
    def initialize(name)
      @name = name
      yield self if block_given?
      @config = find_config_file
      if @config
        define
      else
        task "hydra:remote:#{@name}" do ; end
      end
    end

    private
    def define
      desc "Run #{@name} remotely on all workers"
      task "hydra:remote:#{@name}" do
        config = YAML.load_file(@config)
        environment = config.fetch('environment') { 'test' }
        workers = config.fetch('workers') { [] }
        workers = workers.select{|w| w['type'] == 'ssh'}

        $stdout.write "==== Hydra Running #{@name} ====\n"
        Thread.abort_on_exception = true
        @listeners = []
        @results = {}
        workers.each do |worker|
          @listeners << Thread.new do
            begin
              @results[worker] = if run_task(worker, environment)
                "==== #{@name} passed on #{worker['connect']} ====\n"
              else
                "==== #{@name} failed on #{worker['connect']} ====\nPlease see above for more details.\n"
              end
            rescue 
              @results[worker] = "==== #{@name} failed for #{worker['connect']} ====\n#{$!.inspect}\n#{$!.backtrace.join("\n")}"
            end
          end
        end
        @listeners.each{|l| l.join}
        $stdout.write "\n==== Hydra Running #{@name} COMPLETE ====\n\n"
        $stdout.write @results.values.join("\n")
      end
    end

    def run_task worker, environment
      $stdout.write "==== Hydra Running #{@name} on #{worker['connect']} ====\n"
      ssh_opts = worker.fetch('ssh_opts') { '' }
      writer, reader, error = popen3("ssh -tt #{ssh_opts} #{worker['connect']} ")
      writer.write("cd #{worker['directory']}\n")
      writer.write "echo BEGIN HYDRA\n"
      writer.write("RAILS_ENV=#{environment} rake #{@name}\n")
      writer.write "echo END HYDRA\n"
      writer.write("exit\n")
      writer.close
      ignoring = true
      passed = true
      while line = reader.gets
        line.chomp!
        if line =~ /^rake aborted!$/
          passed = false
        end
        if line =~ /echo END HYDRA$/
          ignoring = true
        end
        $stdout.write "#{worker['connect']}: #{line}\n" unless ignoring
        if line == 'BEGIN HYDRA'
          ignoring = false
        end
      end
      passed
    end
  end

  # A Hydra global task is a task that is run both locally and remotely.
  #
  # For example:
  #
  #   Hydra::GlobalTask.new('db:reset')
  #
  # Allows you to run:
  #   
  #   rake hydra:db:reset
  #
  # Then, db:reset will be run locally and on all remote workers. This
  # makes it easy to setup your workers and run tasks all in a row.
  #
  # For example:
  #
  #   rake hydra:db:reset hydra:factories hydra:tests
  #
  # Assuming you setup hydra:db:reset and hydra:db:factories as global
  # tasks and hydra:tests as a Hydra::TestTask for all your tests
  class GlobalTask < Hydra::Task
    def initialize(name)
      @name = name
      define
    end

    private
    def define
      Hydra::RemoteTask.new(@name)
      desc "Run #{@name.to_s} Locally and Remotely across all Workers"
      task "hydra:#{@name.to_s}" => [@name.to_s, "hydra:remote:#{@name.to_s}"] 
    end
  end
end
