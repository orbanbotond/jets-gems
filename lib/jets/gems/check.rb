# Assumes gems were just built and checks the filesystem to find and detect for
# compiled gems.  Unless the cli option is set to true, the it'll just check
# based on the gemspecs.
module Jets::Gems
  class Check
    extend Memoist

    attr_reader :missing_gems
    def initialize(options={})
      @options = options
      @missing_gems = [] # keeps track of gems that are not found in any of the lambdagems sources
    end

    def run!
      run(exit_early: true)
    end

    # Checks whether the gem is found on at least one of the lambdagems sources.
    # By the time the loop finishes, found_gems will hold a map of gem names to found
    # url sources. Example:
    #
    #   found_gems = {
    #     "nokogiri-1.8.4" => "https://lambdagems.com",
    #     "pg-0.21.0" => "https://anothersource.com",
    #   }
    #
    def run(exit_early: false)
      puts "Checking projects gems for binary Lambda gems..."
      found_gems = {}
      compiled_gems.each do |gem_name|
        puts "Checking #{gem_name}..." if @options[:cli]
        gem_exists = false
        Jets.config.gems.sources.each do |source|
          exist = Jets::Gems::Exist.new(source_url: source)
          found = exist.check(gem_name)
          # gem exists on at least of the lambdagem sources
          if found
            gem_exists = true
            found_gems[gem_name] = source
            break
          end
        end
        unless gem_exists
          @missing_gems << gem_name
        end
      end

      if exit_early && !@missing_gems.empty?
        # Exits early if not all the linux gems are available.
        # Better to error now than deploy a broken package to AWS Lambda.
        # Provide users with message about using their own lambdagems source.
        puts missing_message
        Report.missing(@missing_gems) if agree.yes?
        exit 1
      end

      found_gems
    end

    def missing?
      !@missing_gems.empty?
    end

    def missing_message
      template = <<-EOL
Your project requires compiled gems were not available in any of your lambdagems sources.  Unavailable pre-compiled gems:
<% missing_gems.each do |gem| %>
* <%= gem -%>
<% end %>

Your current lambdagems sources:
<% Jets.config.gems.sources.map do |source| %>
* <%= source -%>
<% end %>

Jets is unable to build a deployment package that will work on AWS Lambda without the required pre-compiled gems. To remedy this, you can:

* Use another gem that does not require compilation.
* Create your own custom layer with the gem: http://rubyonjets.com/docs/custom-lambda-layers/
<% if agree.yes? -%>
* No need to report this to us, as we've already been notified.
<% elsif agree.no? -%>
* You have choosen not to report data to lambdagems so we will not be notified about these missing gems.  If you change your mind you can edit ~/.jets/agree
<% end -%>

Compiled gems usually take some time to figure out how to build as they each depend on different libraries and packages.
More info: http://rubyonjets.com/docs/lambdagems/

EOL
      erb = ERB.new(template, nil, '-') # trim mode https://stackoverflow.com/questions/4632879/erb-template-removing-the-trailing-line
      erb.result(binding)
    end

    def agree
      Agree.new
    end
    memoize :agree

    # If there are subfolders compiled_gem_paths might have files deeper
    # in the directory tree.  So lets grab the gem name and figure out the
    # unique paths of the compiled gems from there.
    def compiled_gems
      # @use_gemspec option  finds compile gems with Gem::Specification
      # The normal build process does not use this and checks the file system.
      # So @use_gemspec is only used for this command:
      #
      #   jets gems:check
      #
      # This is because it seems like some gems like json are remove and screws things up.
      # We'll filter out for the json gem as a hacky workaround, unsure if there are more
      # gems though that exhibit this behavior.
      if @options[:cli]
        gemspec_compiled_gems
      else
        compiled_gems = compiled_gem_paths.map { |p| gem_name_from_path(p) }.uniq
        # Double check that the gems are also in the gemspec list since that
        # one is scoped to Bundler and will only included gems used in the project.
        # This handles the possiblity of stale gems leftover from previous builds
        # in the cache.
        # TODO: figure out if we need
        # compiled_gems.select { |g| gemspec_compiled_gems.include?(g) }
      end
    end

    # Use pre-compiled gem because the gem could have development header shared
    # object file dependencies.  The shared dependencies are packaged up as part
    # of the pre-compiled gem so it is available in the Lambda execution environment.
    #
    # Example paths:
    # Macosx:
    #   opt/ruby/gems/2.5.0/extensions/x86_64-darwin-16/2.5.0-static/nokogiri-1.8.1
    #   opt/ruby/gems/2.5.0/extensions/x86_64-darwin-16/2.5.0-static/byebug-9.1.0
    # Official AWS Lambda Linux AMI:
    #   opt/ruby/gems/2.5.0/extensions/x86_64-linux/2.5.0-static/nokogiri-1.8.1
    # Circleci Ubuntu based Linux:
    #   opt/ruby/gems/2.5.0/extensions/x86_64-linux/2.5.0/pg-0.21.0
    def compiled_gem_paths
      Dir.glob("#{Jets.build_root}/stage/opt/ruby/gems/*/extensions/**/**/*.{so,bundle}")
    end

    # Input: opt/ruby/gems/2.5.0/extensions/x86_64-darwin-16/2.5.0-static/byebug-9.1.0
    # Output: byebug-9.1.0
    def gem_name_from_path(path)
      regexp = %r{opt/ruby/gems/\d+\.\d+\.\d+/extensions/.*?/.*?/(.*?)/}
      path.match(regexp)[1] # gem_name
    end

    # So can also check for compiled gems with Gem::Specification
    # But then also includes the json gem, which then bundler removes?
    # We'll figure out the the json gems.
    # https://gist.github.com/tongueroo/16f4aa5ac5393424103347b0e529495e
    #
    # This is a faster way to check but am unsure if there are more gems than just
    # json that exhibit this behavior. So only using this technique for this commmand:
    #
    #   jets gems:check
    #
    # Thanks: https://gist.github.com/aelesbao/1414b169a79162b1d795 and
    #   https://stackoverflow.com/questions/5165950/how-do-i-get-a-list-of-gems-that-are-installed-that-have-native-extensions
    def specs_with_extensions
      # puts "Jets::Gems::Check#specs_with_extensions".color:red)
      # puts "BUNDLE_GEMFILE #{ENV['BUNDLE_GEMFILE'].inspect}"
      # puts "Jets.root #{Jets.root}"
      # puts "Dir.pwd #{Dir.pwd}"
      # ENV['BUNDLE_GEMFILE'] = nil
      # puts "BUNDLE_GEMFILE2 #{ENV['BUNDLE_GEMFILE'].inspect}"
      # gemfile = IO.readlines("#{Dir.pwd}/Gemfile")
      # puts gemfile

      specs = Gem::Specification.each.select { |spec| spec.extensions.any?  }
      specs.reject! { |spec| weird_gems.include?(spec.name) }
      specs
    end

    def gemspec_compiled_gems
      specs_with_extensions.map(&:full_name)
    end

    # Filter out the weird special case gems that bundler deletes?
    # Probably to fix some bug.
    #
    #   $ bundle show json
    #   The gem json has been deleted. It was installed at:
    #   /home/ec2-user/.rbenv/versions/2.5.1/lib/ruby/gems/2.5.0/gems/json-2.1.0
    #
    def weird_gems
      %w[json]
    end
  end
end