require 'thread'

module Hawkins
  module Commands
    class LiveServe < Jekyll::Command
      class << self
        COMMAND_OPTIONS = {
          "swf"      => ["--swf", "Use Flash for WebSockets support"],
          # TODO Should probably only accept fnmatch-esque strings and convert them to regexs
          "ignore"   => ["--ignore [REGEX]", "Files not to reload"],
          "min_delay" => ["--min-delay [SECONDS]", "Minimum reload delay"],
          "max_delay" => ["--max-delay [SECONDS]", "Maximum reload delay"],
          "reload_port" => ["--reload-port [PORT]", Integer, "Port for LiveReload to listen on"],
        }.merge(Jekyll::Commands::Serve.singleton_class::COMMAND_OPTIONS).freeze

        LIVERELOAD_PORT = 35729

        #

        def init_with_program(prog)
          prog.command(:liveserve) do |cmd|
            cmd.description "Serve your site locally with LiveReload"
            cmd.syntax "liveserve [options]"
            cmd.alias :liveserver
            cmd.alias :l

            add_build_options(cmd)
            COMMAND_OPTIONS.each do |key, val|
              cmd.option(key, *val)
            end

            cmd.action do |_, opts|
              # TODO need to figure out how to set defaults correctly
              opts["reload_port"] ||= LIVERELOAD_PORT

              opts["serving"] = true
              opts["watch"] = true unless opts.key?("watch")
              start(opts)
            end
          end
        end

        def start(opts)
          opts = configuration_from_options(opts)

          @running = Queue.new
          @reload_reactor = LiveReloadReactor.new(opts)
          @reload_reactor.start
          Jekyll::Commands::Build.process(opts)
          LiveServe.process(opts)
        end

        def process(opts)
          destination = opts["destination"]
          setup(destination)

          @server = WEBrick::HTTPServer.new(webrick_opts(opts)).tap { |o| o.unmount("") }

          @server.mount("#{opts['baseurl']}/__livereload",
            WEBrick::HTTPServlet::FileHandler, LIVERELOAD_DIR)
          @server.mount(opts["baseurl"], ReloadServlet, destination, file_handler_opts)

          Jekyll.logger.info "Server address:", server_address(@server, opts)
          launch_browser(@server, opts) if opts["open_url"]
          boot_or_detach(@server, opts)
        end

        def running?
          !(@running.nil? || @running.empty?)
        end

        def shutdown
          @server.shutdown if running?
        end

        # Do a base pre-setup of WEBRick so that everything is in place
        # when we get ready to party, checking for an setting up an error page
        # and making sure our destination exists.

        private
        def setup(destination)
          require_relative "./servlet"

          FileUtils.mkdir_p(destination)
          if File.exist?(File.join(destination, "404.html"))
            WEBrick::HTTPResponse.class_eval do
              def create_error_page
                @header["Content-Type"] = "text/html; charset=UTF-8"
                @body = IO.read(File.join(@config[:DocumentRoot], "404.html"))
              end
            end
          end
        end

        #

        private
        def webrick_opts(opts)
          opts = {
            :JekyllOptions      => opts,
            :DoNotReverseLookup => true,
            :MimeTypes          => mime_types,
            :DocumentRoot       => opts["destination"],
            :StartCallback      => start_callback(opts["detach"]),
            :StopCallback       => stop_callback(opts["detach"]),
            :BindAddress        => opts["host"],
            :Port               => opts["port"],
            :DirectoryIndex     => %w(
              index.htm
              index.html
              index.rhtml
              index.cgi
              index.xml
            ),
          }

          enable_ssl(opts)
          enable_logging(opts)
          opts
        end

        # Recreate NondisclosureName under utf-8 circumstance

        private
        def file_handler_opts
          WEBrick::Config::FileHandler.merge(
            :FancyIndexing     => true,
            :NondisclosureName => [
              '.ht*', '~*'
            ]
          )
        end

        #

        private
        def server_address(server, opts)
          address = server.config[:BindAddress]
          baseurl = "#{opts['baseurl']}/" if opts["baseurl"]
          port = server.config[:Port]

          if opts['ssl_cert'] && opts['ssl_key']
            protocol = "https"
          else
            protocol = "http"
          end

          "#{protocol}://#{address}:#{port}#{baseurl}"
        end

        #

        private
        def launch_browser(server, opts)
          command =
            if Utils::Platforms.windows?
              "start"
            elsif Utils::Platforms.osx?
              "open"
            else
              "xdg-open"
            end
          system command, server_address(server, opts)
        end

        # Keep in our area with a thread or detach the server as requested
        # by the user.  This method determines what we do based on what you
        # ask us to do.

        private
        def boot_or_detach(server, opts)
          if opts["detach"]
            pid = Process.fork do
              server.start
            end

            Process.detach(pid)
            Jekyll.logger.info "Server detached with pid '#{pid}'.", \
              "Run `pkill -f jekyll' or `kill -9 #{pid}' to stop the server."
          else
            t = Thread.new { server.start }
            trap("INT") { server.shutdown }
            t.join
          end
        end

        # Make the stack verbose if the user requests it.

        private
        def enable_logging(opts)
          opts[:AccessLog] = []
          level = WEBrick::Log.const_get(opts[:JekyllOptions]["verbose"] ? :DEBUG : :WARN)
          opts[:Logger] = WEBrick::Log.new($stdout, level)
        end

        # Add SSL to the stack if the user triggers --enable-ssl and they
        # provide both types of certificates commonly needed.  Raise if they
        # forget to add one of the certificates.

        private
        def enable_ssl(opts)
          jekyll_opts = opts[:JekyllOptions]
          return if !jekyll_opts['ssl_cert'] && !jekyll_opts['ssl_key']
          if !jekyll_opts['ssl_cert'] || !jekyll_opts['ssl_key']
            raise "--ssl-cert or --ssl-key missing."
          end

          Jekyll.logger.info("LiveReload:", "Serving over SSL/TLS.  If you are using a "\
            "certificate signed by an unknown CA, you will need to add an exception for both "\
            "#{jekyll_opts['host']}:#{jekyll_opts['port']} and "\
            "#{jekyll_opts['host']}:#{jekyll_opts['reload_port']}")

          require "openssl"
          require "webrick/https"
          source_key = Jekyll.sanitized_path(jekyll_opts['source'], jekyll_opts['ssl_key'])
          source_certificate = Jekyll.sanitized_path(jekyll_opts['source'], jekyll_opts['ssl_cert'])
          opts[:SSLCertificate] = OpenSSL::X509::Certificate.new(File.read(source_certificate))
          opts[:SSLPrivateKey] = OpenSSL::PKey::RSA.new(File.read(source_key))
          opts[:SSLEnable] = true
        end

        private
        def start_callback(detached)
          unless detached
            proc do
              @running << '.'
              Jekyll.logger.info("Server running...", "press ctrl-c to stop.")
            end
          end
        end

        private
        def stop_callback(detached)
          unless detached
            proc do
              @reload_reactor.stop
              @running.clear
            end
          end
        end

        private
        def mime_types
          file = File.expand_path('../mime.types', File.dirname(__FILE__))
          WEBrick::HTTPUtils.load_mime_types(file)
        end
      end
    end
  end
end
