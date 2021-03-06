# Git Pivotal Tracker Integration
# Copyright (c) 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module GitPivotalTrackerIntegration
  module Command

    # An abstract base class for all commands
    # @abstract Subclass and override {#run} to implement command functionality
    class Base

      # Common initialization functionality for all command classes.  This
      # enforces that:
      # * the command is being run within a valid Git repository
      # * the user has specified their Pivotal Tracker API token
      # * all communication with Pivotal Tracker will be protected with SSL
      # * the user has configured the project id for this repository
      def initialize
        self.start_logging
        self.check_version

        git_global_push_default = (Util::Shell.exec "git config --global push.default", false).chomp
        if git_global_push_default != "simple"
          puts "git config --global push.default simple"
          puts Util::Shell.exec "git config --global push.default simple"
        end

        @repository_root  = Util::Git.repository_root
        @configuration    = Command::Configuration.new

        @configuration.check_for_config_file
        @configuration.check_for_config_contents

        @client           = TrackerApi::Client.new(:token => @configuration.api_token, :logger => Logger.new('faraday.log'))
        @platform         = @configuration.platform_name

        current_project_id  = @configuration.project_id.to_i
        @project            = @client.project current_project_id
        my_projects         = @client.projects

        unless my_projects && my_projects.map(&:id).include?(current_project_id)
          project_manager_name  = @configuration.pconfig["project"]["project-manager"]
          project_manager_email = @configuration.pconfig["project"]["project-manager-email"]
          project_name          = @configuration.pconfig["project"]["project-name"]
          abort "This project requires access to the Pivotal Tracker project [#{project_name} - #{current_project_id}]. Please speak with project manager [#{project_manager_name} - #{project_manager_email}] and ask him to add you to the project in Pivotal Tracker."
        end
      end

      def start_logging
        $LOG = Logger.new("#{logger_filename}", 'weekly')
      end

      def logger_filename
        return "#{Dir.home}/.v2gpti_local.log"
      end

      def check_version
        gem_latest_version    = (Util::Shell.exec "gem list v2gpti --remote")[/\(.*?\)/].delete "()"
        gem_installed_version = Gem.loaded_specs["v2gpti"].version.version
        if (gem_installed_version == gem_latest_version)
            $LOG.info("v2gpti verison #{gem_installed_version} is up to date.")
        else
            $LOG.fatal("Out of date")
            if OS.windows?
              abort "\n\nYou are using v2gpti version #{gem_installed_version}, but the current version is #{gem_latest_version}.\nPlease update your gem with the following command.\n\n    gem update v2gpti\n\n"
            else
    		  abort "\n\nYou are using v2gpti version #{gem_installed_version}, but the current version is #{gem_latest_version}.\nPlease update your gem with the following command.\n\n    sudo gem update v2gpti\n\n"
    		end
        end
      rescue StandardError => se
        puts ""
      end

      # The main entry point to the command's execution
      # @abstract Override this method to implement command functionality
      def run
        raise NotImplementedError
      end


      def seconds_spent(time_spent)
        seconds = 0
        time_spent.scan(/(\d+)(\w)/).each do |amount, measure|
          seconds += amount.to_i * TIMER_TOKENS[measure]
        end
        seconds
      end
      def estimated_seconds(story)
        estimate = story.estimate
        seconds = 0
        case estimate
          when 0
            estimate = 15 * 60
          when 1
            estimate = 1.25 * 60 * 60
          when 2
            estimate = 3 * 60 * 60
          when 3
            estimate = 8 * 60 * 60
          else
            estimate = -1 * 60 * 60
        end
        estimate
      end

      def create_story(args)
        story_types = {"f" => "feature", "b" => "bug", "c" => "chore"}
        new_story_type = nil
        new_story_title = nil
        new_story_estimate = -1
        args.each do |arg|
          new_story_type = story_types[arg[-1]] if arg.include? '-n'
          new_story_title = arg if arg[0] != "-"
        end

        while new_story_type.nil?
          nst = ask("Please enter f for feature, b for bug, or c for chore")
          new_story_type = story_types[nst]
        end

        while (new_story_title.nil? || new_story_title.empty?)
          new_story_title = ask("Please enter the title for this #{new_story_type}.")
        end

        attrs = {:story_type => new_story_type, :current_state => 'unstarted', :name => new_story_title}

        if @project.bugs_and_chores_are_estimatable
          attrs[:estimate] = estimate_story
        else
          if (new_story_type == "feature" && (new_story_estimate < 0 || new_story_estimate > 3))
            attrs[:estimate] = estimate_story
          end
        end

        @project.create_story(attrs)

      end

      def create_icebox_bug_story(args)
        create_story_with_type_state("bug", "unscheduled", args)
      end

      def create_backlog_bug_story(args)
        create_story_with_type_state("bug", "unstarted", args)
      end

      def create_icebox_feature_story(args)
        create_story_with_type_state("feature", "unscheduled", args)
       end

      def create_backlog_feature_story(args)
        create_story_with_type_state("feature", "unstarted", args)
      end

      private

      def pwd
        command = OS.windows? ? 'echo %cd%': 'pwd'
        Util::Shell.exec(command).chop
      end

      def estimate_story
        point_scale = @project.point_scale
        point_scale_arr = point_scale.split(',').map(&:to_s)

        estimate = ask("Please enter the estimate points(#{point_scale}) for this story.") do |q|
          q.in = point_scale_arr
          q.responses[:not_in_range] = "Invalid entry...Please enter the estimate points(#{point_scale}) for this story."
        end
        estimate.to_i
      end

      def estimate_story_optional
        point_scale = @project.point_scale
        point_scale_arr = point_scale.split(',').map(&:to_s).push("n")

        estimate  = ask("Please enter the estimate points(#{point_scale}) for this feature story.\nIf you don't want to estimate then enter n") do |q|
                      q.in = point_scale_arr
                      q.responses[:not_in_range] = "Invalid entry...Please enter the estimate points(#{point_scale}) for this feature story.\nIf you don't want to estimate then enter n"
                    end
        if estimate == "n"
          estimate = nil
        else
          estimate.to_i
        end
      end

      def create_story_with_type_state(type, state, args)
        story_title   = nil
        story_points  = nil

        args.each {|arg| story_title = arg if arg[0] != "-" }

        while (story_title.nil? || story_title.empty?)
          story_title = ask("Please enter the title for the story")
        end

        story_params = {:story_type => type, :current_state => state, :name => story_title}

        # if it is a feature, get the estimate for the story.
        # if it is not provided in the command line, ask for it
        if (type == "feature" or @project.bugs_and_chores_are_estimatable) #set the story points
          args.each do |arg|
            story_points = arg[2] if arg[0] == "-" && arg[1].downcase == "p"
          end
          story_points = estimate_story_optional if story_points.nil? || story_points.empty?
          story_params[:estimate] = story_points unless story_points.nil?
        end

        story = @project.create_story(story_params)

        #move the story
        stories = @project.stories(:with_state => state, :fields => 'name')

        if args.any?{|arg| arg.include?("-tl") } && !(stories.empty? || stories.nil?)
          story.before_id = stories.first.id
        elsif args.any?{|arg| arg.include?("-bl")} && !(stories.empty? || stories.nil?)
          story.after_id = stories.last.id
        end

        story.save
        story
      end

    end

  end
end
