#!/usr/bin/ruby
require 'rubygems'
require 'json'
require 'yaml'
require 'rest-client'
require 'active_support/all'
require 'action_mailer'
require 'readline'
require 'net/smtp'

class Pullr
  CONFIG_FILE = "pullr.yml"
  cattr_accessor :do_log
  def initialize(options = {})
    log "Initializing Pullr with - #{options.to_json}"
    login = options.delete('login') or raise 'No GitHub login found'
    token = options.delete('token')
    credentials = token.blank? ? ":#{options.delete('password')}" : "/token:#{token}"
    raise "No GitHub credentials found" if credentials.empty? or credentials == ':'

    @issue_number = options.delete('issue_number')
    raise 'No issue number chosen' if @issue_number.blank?
    @repo = options.delete('repo')
    raise 'No repo chosen' if @repo.blank?
    @target_tree = options.delete('name')
    raise 'No target chosen' if @target_tree.blank?
    @source_tree = options.delete('use_fork') ? login : @target_tree
    @target_branch = options.delete('target_branch')
    @target_branch = options.delete('mainline') if @target_branch.blank?
    @target_branch = 'master' if @target_branch.blank?
    @resolves_issue = !options.delete('resolves_issue').blank?
    @build_number = options.delete('build_number')
    raise 'No build number' if @build_number.blank?

    @smtp_options = options.delete('smtp')
    @email_options = options.delete('email')

    base_url = "https://#{login}#{credentials}@github.com/api/v2/json/"
    @urls = {
            :issues => {:view => "#{base_url}issues/show/#{@target_tree}/#{@repo}/#{@issue_number}",
                        :comments => "https://#{login}#{credentials}@api.github.com/repos/#{@target_tree}/#{@repo}/issues/#{@issue_number}/comments",
                        :labels => "https://#{login}#{credentials}@api.github.com/repos/#{@target_tree}/#{@repo}/issues/#{@issue_number}/labels",
            },
            :branches => {:list => "#{base_url}repos/show/#{@source_tree}/#{@repo}/branches"},
            :pulls => {:create => "#{base_url}pulls/#{@target_tree}/#{@repo}"},
    }
  end

  def self.configure
    file_name = File.join(File.dirname(__FILE__), CONFIG_FILE)
    config = YAML::load(File.open(file_name))
    self.do_log = config.delete('log')
    log "Loading config from #{file_name}"

    repos = config.delete('repos')
    raise 'No repos configured' if repos.blank?
    case repos.count
      when 1
        repos[repos.keys.first]
      else
        repo_arr = repos.keys.sort.inject([]){|arr,key|arr << repos[key]; arr}
        puts "\nThe following repos are available: "
        range = (0..repo_arr.length - 1).to_a
        repos.keys.sort.each_with_index {|repo, i| puts "\t#{i} - #{repo}"}
        begin
          repo_no = Readline.readline "\nChoose a number corresponding to the repo you want [#{range.join ', '}] > "
        end until repo_no =~ /^\d+$/ and range.include? repo_no.to_i
        repo_arr[repo_no.to_i]
    end.each {|k,v| config[k] = v}

    config['issue_number'] = get_int 'Issue Number', guess_issue_number
    config['build_number'] = get_int 'Build Number'

    config['resolves_issue'] = get_yes_no_answer "Does the pull request close an issue?"
    config['use_fork'] =  get_yes_no_answer "Pull from your own fork?", false

    target_branch = Readline.readline "Pull to what branch? (press enter for mainline branch) > ", true
    config['target_branch'] = target_branch unless target_branch.blank?
    Pullr.new(config)
  end

  def do
    puts "\nChecking issues and branches on GitHub...\n"
    issue = find_issue
    issue_title = "#{@issue_number} - #{issue['title']}"
    puts "ISSUE #{issue_title}"
    branch_to_pull = "#{@source_tree}:#{find_branch}"
    ensure_unique_issue_size
    puts "\nCREATE #{@resolves_issue ? 'ISSUE' : 'DEPLOYMENT'} PULL REQUEST"
    puts "For issue   #{issue_title}"
    puts "from branch #{branch_to_pull}"
    puts "to branch   #{@target_tree}:#{@target_branch}\n"
    puts "Build #     #{@build_number}"
    unless Pullr.get_yes_no_answer "Is that OK?", false
      puts "\nEXITING - no pull request created\n"
    else
      # Add comment with 'build certificate'
      do_api_call @urls[:issues][:comments], nil, {:body => "http://192.168.1.115:8111/viewLog.html?buildId=#{@build_number}"}.to_json

      params = {:pull => {:base => @target_branch, :head => branch_to_pull}}
      if @resolves_issue
        params[:pull][:issue] = @issue_number
      else
        params[:pull][:title] = "DEPLOYMENT PULL REQUEST FOR #{issue_title}"
        params[:pull][:body] = "##{@issue_number}"
      end
      do_api_call @urls[:pulls][:create], "pull", params
      puts "\nCREATED PULL REQUEST!\n"

      if @smtp_options and @email_options
        puts "\nSending notification to #{@email_options["to"]}...\n"
        ActionMailer::Base.smtp_settings = {
                :enable_starttls_auto => true,
                :address =>  @smtp_options["server"],
                :port => @smtp_options.delete("port") || 25,
                :domain => @smtp_options["domain"],
                :authentication => :plain,
                :user_name => @smtp_options["user_name"],
                :password => @smtp_options["password"]
        }
        PullrMailer.deliver_notification(@email_options["from"], @email_options["to"], "PULLR - Pull Request Created for #{issue_title}", "Please review at https://github.com/#{@target_tree}/#{@repo}/pulls/#{@issue_number}")
      end

    end
  end

  private
  def do_api_call(url, object_name = nil, params = {}, options = {})
    reply = if params.blank?
      log "Getting #{url.gsub(/\/\/.*@/, '//')}"
      RestClient.get(url)
    elsif !options.delete(:put).blank?
      log "Putting to #{url.gsub(/\/\/.*@/, '//')} with options #{params.to_json}"
      RestClient.put(url, params)
    else
      log "Posting to #{url.gsub(/\/\/.*@/, '//')} with options #{params.to_json}"
      RestClient.post(url, params)
    end
    unless reply.blank?
      log "Received the following reply: #{reply}"
      if object_name # GitHub API v2 has an object name as the key for the returned values
        JSON.parse(reply)[object_name]
      else
        JSON.parse(reply)
      end
    end
  end

  def ensure_unique_issue_size
    labels = do_api_call(@urls[:issues][:labels])
    sizes = labels.inject([]) do |array, label|
      if label['name'] =~ /^size_(\d+)$/
        array << $1.to_i
      end
      array
    end
    return sizes[0] if sizes.length == 1 and Pullr.get_yes_no_answer "Issue size is currently #{sizes[0]} - is that OK?"
    size = Pullr.get_int "Choose an issue size from 1 to 10#{"(sizes #{sizes.join ','} are currently selected)" if sizes.length > 1}", nil, 10
    new_labels = labels.reject { |l| l['name'] =~ /^size/ }.map { |l| l['name'] }
    new_labels << "size_#{size}"
    do_api_call @urls[:issues][:labels], nil, new_labels, {:put => true}
    size
  end

  def find_issue
    do_api_call @urls[:issues][:view], "issue"
  end

  def find_branch
    all_branches = do_api_call(@urls[:branches][:list], "branches")
    candidate_branches = all_branches.keys.select{|branch| /^#{@issue_number}/ =~ branch}
    raise "#{candidate_branches.count} branches found" unless candidate_branches.count == 1
    candidate_branches.first
  end

  def log(message)
    Pullr.log message
  end

  def self.log(message)
    puts message if self.do_log
  end

  def self.guess_issue_number
    # grab any integer appearing after a slash in the output of `git symbolic-ref HEAD`,
    # which should be something like "refs/heads/999-some-big-issue\n"
    $1 if `git symbolic-ref HEAD 2> /dev/null` =~ /\/(\d+)/
  end

  def self.get_yes_no_answer(prompt, default_is_yes = true)
    begin
      answer = Readline.readline "#{prompt} [#{default_is_yes ? 'Y/n' : 'y/N'}] > "
    end until answer.blank? or answer =~ /^y|n$/i
    return default_is_yes if answer.blank?
    answer !~ /n/i # return true if the answer is not 'n'
  end

  def self.get_int(prompt, default = nil, limit = nil)
    begin
      number = Readline.readline("#{prompt}#{" [#{default}]" if default} > ", true)
      number = default if default and number.blank?
    end while number !~ /^\d+$/ and (!limit or number.to_i <= limit)
    number.to_i
  end

end

class PullrMailer < ActionMailer::Base
  def notification(from, to, subject, content)
    recipients to
    from from
    subject subject
    body content
  end
end

begin
  Pullr.configure.do
rescue => e
  puts "ERROR - #{e.message}"
end
