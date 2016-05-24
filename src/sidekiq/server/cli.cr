require "option_parser"

require "../../sidekiq"
require "./server"

module Sidekiq
  class CLI

    getter logger : ::Logger

    def initialize(args=ARGV)
      @concurrency = 25
      @queues = [] of String
      @timeout = 8
      @environment = "development"
      @tag = ""
      @logger = Sidekiq::Logger.build

      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: sidekiq [arguments]"
        parser.on("-c NUM", "Number of workers") { |c| @concurrency = c.to_i }
        parser.on("-e ENV", "Application environment") { |e| @environment = e }
        parser.on("-g TAG", "Process description") { |e| @tag = e }
        parser.on("-q NAME,[WEIGHT]", "Process queue NAME, with optional weight") do |q|
          ary = q.split(',', 2)
          if ary.size == 2
            name, weight = ary
            weight.to_i.times { @queues << name }
          else
            @queues << ary[0]
          end
        end
        parser.on("-t SEC", "Shutdown timeout") { |t| @timeout = t.to_i }
        parser.on("-v", "Enable verbose logging") do |c|
          @logger.level = ::Logger::DEBUG
        end
        parser.on("-V", "Print version and exit") { |c| puts "Sidekiq #{Sidekiq::VERSION}"; exit }
        parser.on("-h", "--help", "Show this help") { puts parser }
      end

      @queues = ["default"] if @queues.empty?
    end

    def create(logger = @logger)
      Sidekiq::Server.new(concurrency: @concurrency,
                          queues: @queues,
                          environment: @environment,
                          logger: logger)
    end

    def configure(logger = @logger)
      x = create(logger)
      yield x
      x.validate
      x
    end

    def run(svr)
      # hack to avoid printing banner in test suite
      print_banner if logger == @logger
      logger.info "Sidekiq v#{Sidekiq::VERSION} in #{{{`crystal -v`.strip.stringify}}}"
      logger.info Sidekiq::LICENSE
      logger.info "Upgrade to Sidekiq Enterprise for more features and support: http://sidekiq.org"
      logger.info "Starting processing with #{@concurrency} workers"

      logger.debug { self.inspect }

      svr.start
      shutdown_started_at = nil

      Signal::INT.trap do
        shutdown_started_at = Time.now
        svr.request_stop
      end
      Signal::TERM.trap do
        shutdown_started_at = Time.now
        svr.request_stop
      end
      Signal::USR1.trap do
        svr.request_stop
      end

      logger.info "Press Ctrl-C to stop"

      until shutdown_started_at
        sleep 1
      end

      deadline = shutdown_started_at.not_nil! + @timeout.seconds
      while Time.now < deadline && !svr.processors.empty?
        sleep 0.1
      end

      if !svr.processors.empty?
        logger.info "Re-enqueuing #{svr.processors.size} busy jobs"
        svr.fetcher.bulk_requeue(svr, svr.processors.map { |p| p.job }.compact)
      end

      logger.info "Done, bye!"
      exit(0)
    end


    def banner
%{
         m,
         `$b
    .ss,  $$:         .,d$
    `$$P,d$P'    .,md$P"'
     ,$$$$$bmmd$$$P^'
   .d$$$$$$$$$$P'
   $$^' `"^$$$'       ____  _     _      _    _
   $:     ,$$:       / ___|(_) __| | ___| | _(_) __ _
   `b     :$$        \___ \| |/ _` |/ _ \ |/ / |/ _` |
          $$:         ___) | | (_| |  __/   <| | (_| |
          $$         |____/|_|\__,_|\___|_|\_\_|\__, |
        .d$$                                       |_|
}
    end

    def print_banner
      if STDOUT.tty? && @environment == "development"
        puts "\e[#{31}m"
        puts banner
        puts "\e[0m"
      end
    end

  end
end