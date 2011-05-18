#!/usr/bin/ruby
require 'rubygems'
require 'json'
require 'yaml'
require 'rest-client'
require 'active_support/all'
require 'readline'

class Pullr
  CONFIG_FILE = "pullr.yml"

  def initialize(options = {})
    @log = options.delete('log')
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

    base_url = "https://#{login}#{credentials}@github.com/api/v2/json/"
    @urls = {
            :issues => {:view => "#{base_url}issues/show/#{@target_tree}/#{@repo}/#{@issue_number}"},
            :branches => {:list => "#{base_url}repos/show/#{@source_tree}/#{@repo}/branches"},
            :pulls => {:create => "#{base_url}pulls/#{@target_tree}/#{@repo}"},
    }
  end

  def self.configure
    file_name = File.join(File.dirname(__FILE__), CONFIG_FILE)
    log "Loading config from #{file_name}"
    config = YAML::load(File.open(file_name))

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

    begin
      issue_number = Readline.readline 'Issue Number > ', true
    end while issue_number !~ /^\d+$/
    config['issue_number'] = issue_number.to_i

    config['resolves_issue'] = get_yes_no_answer "Does the pull request close an issue?"
    config['use_fork'] =  get_yes_no_answer "Pull from your own fork?"

    target_branch = Readline.readline "Pull to what branch? (press enter for mainline branch) > ", true
    config['target_branch'] = target_branch unless target_branch.blank?
    Pullr.new(config)
  end

  def do
    puts "\nChecking issues and branches on GitHub...\n"
    issue = find_issue
    issue_title = "#{@issue_number} - #{issue['title']}"
    branch_to_pull = "#{@source_tree}:#{find_branch}"
    puts "\nCREATE #{@resolves_issue ? 'ISSUE' : 'DEPLOYMENT'} PULL REQUEST"
    puts "For issue   #{issue_title}"
    puts "from branch #{branch_to_pull}"
    puts "to branch   #{@target_tree}:#{@target_branch}\n"
    unless Pullr.get_yes_no_answer "Is that OK?", false
      puts "\nEXITING - no pull request created\n"
    else
      url = @urls[:pulls][:create]
      options = {:pull => {:base => @target_branch, :head => branch_to_pull}}
      if @resolves_issue
        options[:pull][:issue] = @issue_number
      else
        options[:pull][:title] = "DEPLOYMENT PULL REQUEST FOR #{issue_title}"
        options[:pull][:body] = "##{@issue_number}"
      end
      do_api_call url, "pull", options
      puts "\nCREATED PULL REQUEST!\n"
      # TODO - add 'certificate of build', comments?
    end
  end

  private
  def do_api_call(url, object_name, options = {})
    reply = case options.blank?
      when true
        log "Getting #{url.gsub(/\/\/.*@/, '//')}"
        RestClient.get(url)
      else
        log "Posting to #{url.gsub(/\/\/.*@/, '//')} with options #{options.to_json}"
        RestClient.post(url, options)
    end
    log "Received the following reply: #{reply}" unless reply.blank?
    JSON.parse(reply)[object_name]
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
    puts message if @log
  end

  def self.get_yes_no_answer(prompt, default_is_yes = true)
    begin
      answer = Readline.readline "#{prompt} [#{default_is_yes ? 'Yn' : 'yN'}] > "
    end until answer.blank? or answer =~ /^y|n$/i
    return default_is_yes if answer.blank?
    answer !~ /n/i # return true if the answer is not 'n'
  end

end

begin
  Pullr.configure.do
rescue => e
  puts "ERROR - #{e.message}"
end
