
require 'base64'
require 'digest/md5'
require 'erb'
require 'etc'
require 'iconv'
require 'logger'
require 'net/http'
require 'net/https'
require 'net/smtp'
require 'optparse'
require 'ostruct'
require 'pathname'
require 'singleton'
require 'tempfile'
require 'uri'
require 'yaml'

# ruby gem dependencies
require 'diff-lcs'
require 'htmlentities'

# wcc
require 'wcc/diff'
require 'wcc/filter'
require 'wcc/mail'
require 'wcc/site'
require 'wcc/syslog'
require 'wcc/version'

class String
	# Remove all HTML tags with at least one character name and
	# decode all HTML entities into utf-8 characters.
	#
	# @return [String] stripped string
	def strip_html
		HTMLEntities.new.decode(self.gsub(/<[^>]+>/, ' '))
	end
	
	# Returns all characters from the i-th to the end.
	# 
	# @param [Integer] i offset to start substring
	# @return [String] slice(i...length)
	def substring(i)
		slice(i...length)
	end
end

class Hash
	# Recursively merges the other hash into self while
	# overwriting duplicate keys in self.
	#
	# @param [Hash] other the hash to get merged in
	# @return [Hash] copy of self with other hash merged in
	def recursive_merge(other)
		copy = self.dup
		other.keys.each do |k|
			if other[k].is_a?(Hash) and self[k].is_a?(Hash)
				copy[k] = copy[k].recursive_merge(other[k])
			else
				# ignore nils from other
				copy[k] = other[k] unless other[k].nil?
			end
		end
		copy
	end
end

module WCC

	DIFF_TIME_FMT = '%Y-%m-%d %H:%M:%S %Z'
	
	# logging via WCC.logger.blub
	
	def self.logger
		@logger
	end
	
	def self.logger=(logger)
		@logger = logger
	end
	
	class Conf
		include Singleton
		
		attr_reader :recipients
		
		# use Conf like a hash containing all options
		def [](key)
			@options[key.to_sym] || Conf.default[key.to_sym]
		end
		def []=(key, val)
			@options[key.to_sym] = val unless val.nil?
		end
		
		def self.default
			@default_conf ||= {
				:verbose => false,
				:debug => false,
				:simulate => false,
				:clean => false,
				:nomails => false,
				:stats => false,
				# when you want to use ./tmp it must be writeable
				:cache_dir => '/var/tmp/wcc',
				:tag => 'wcc',
				:filter_dir => './filter.d',
				:template_dir => './template.d'
			}
		end
		
		def initialize
			@options = {}
			
			OptionParser.new do |opts|
				opts.banner =  "Usage: ruby wcc.rb [options] [config-yaml-file]"
				opts.banner += "\nOptions:\n"
				opts.on('-v', '--verbose', 'Output more information') do self[:verbose] = true end
				opts.on('-d', '--debug', 'Enable debug mode') do self[:debug] = true end
				opts.on('--cache-dir DIR', 'Save hash and diff files to DIR') do |dir| self[:cache_dir] = dir end
				opts.on('-s', '--simulate', 'Check for update but do not save hash or diff files') do self[:simulate] = true end
				opts.on('--clean', 'Remove all saved hash and diff files') do self[:clean] = true end
				opts.on('-t', '--tag TAG', 'Set TAG used in output') do |t| self[:tag] = t end
				opts.on('-n', '--no-mails', 'Do not notify users in any way') do self[:nomails] = true end
				opts.on('--show-config', 'Show config after loading config file (debug purposes)') do self[:show_config] = true end
				opts.on('-h', '-?', '--help', 'Display this screen') do
					puts opts
					exit
				end
			end.parse!
			
			WCC.logger.progname = 'wcc'

			# latest flag overrides everything
			WCC.logger.level = Logger::ERROR
			WCC.logger.level = Logger::INFO if self[:verbose]
			WCC.logger.level = Logger::DEBUG if self[:debug]
			
			WCC.logger.formatter = LogFormatter.new((self[:verbose] or self[:debug]))

			# main
			WCC.logger.info "web change checker (aka wcc) #{WCC::VERSION}"
			WCC.logger.info "Licensed under Apache License Version 2.0"
			
			WCC.logger.info "No config file given, using default 'conf.yml' file" if ARGV.length == 0

			self[:conf] = ARGV[0] || 'conf.yml'
			
			if !File.exists?(self[:conf])
				WCC.logger.fatal "Config file '#{self[:conf]}' does not exist!"
				Prog.exit 1
			end
			
			# register standard notificators - these are already loaded
			Notificators.map 'email', MailNotificator
			Notificators.map 'syslog', SyslogNotificator
			
			WCC.logger.debug "Load config from '#{self[:conf]}'"
			
			# may be false if file is empty
			yaml = YAML.load_file(self[:conf])
			
			# inject dummy value {} for 'email' in 'conf' section to make the parser
			# load MailNotificator and it's defaults even if the key is missing
			# since email has always been the backbone of wcc
			yaml = {'conf' => {'email' => {}}}.recursive_merge(yaml) if yaml.is_a?(Hash)
			
			if yaml.is_a?(Hash) and yaml['conf'].is_a?(Hash)
				yaml['conf'].each do |key,val|
					case key
					when 'cache_dir'
						@options[:cache_dir] ||= val
					when 'tag'
						@options[:tag] ||= val
					when 'filterd'
						@options[:filter_dir] ||= val
					when 'templated'
						@options[:template_dir] ||= val
					when 'stats'
						@options[:stats] ||= val
					else
						if not Notificators.mappings.include?(key)
							plugin_name = "wcc-#{key}-notificator"
							WCC.logger.info "Trying to load plugin #{plugin_name}..."
							begin
								require plugin_name
							rescue LoadError
								WCC.logger.error "Plugin #{plugin_name} not found - maybe try `gem install #{plugin_name}`"
								next
							end
						end
						Notificators.mappings[key].parse_conf(val).each { |k,v| @options[k] ||= v }
					end
				end
			end
			
			if self[:show_config]
				Conf.default.merge(@options).each do |k,v|
					puts "  #{k.to_s} => #{self[k]}"
				end
				Prog.exit 0
			end
			
			@recipients = {}
			WCC.logger.debug "Load recipients from '#{self[:conf]}'"
			# may be *false* if file is empty
			yaml = YAML.load_file(self[:conf])
			if not yaml
				WCC.logger.info "No recipients loaded"
			else
				yaml['recipients'].to_a.each do |yaml_rec|
					name = yaml_rec.keys.first
					rec = []
					yaml_rec[name].to_a.each do |yaml_way|
						# TODO: find options and pass them to every notificator
						if yaml_way.is_a?(Hash)
							new_notificator(name, yaml_way.keys.first, yaml_way[yaml_way.keys.first], rec)
						else
							new_notificator(name, yaml_way, nil, rec)
						end
					end
					@recipients[name] = rec
				end
			end
			
			# attach --no-mails filter
			WCC::Filters.add '--no-mails' do |data|
				!self[:nomails]
			end
		end
		
		def self.sites
			return @sites unless @sites.nil?
			
			@sites = []
			
			WCC.logger.debug "Load sites from '#{Conf[:conf]}'"
			# may be *false* if file is empty
			yaml = YAML.load_file(Conf[:conf])
			if not yaml
				WCC.logger.info "No sites loaded"
				return @sites
			end
			
			yaml['sites'].to_a.each do |yaml_site|
				# query --no-mails filter for every site
				frefs = [FilterRef.new('--no-mails')]
				(yaml_site['filters'] || []).each do |entry|
					if entry.is_a?(Hash)
						# hash containing only one key (filter id),
						# the value is the argument hash
						id = entry.keys[0]
						frefs << FilterRef.new(id, entry[id])
					else entry.is_a?(String)
						frefs << FilterRef.new(entry)
					end
				end
				
				if not yaml_site['cookie'].nil?
					cookie = File.open(yaml_site['cookie'], 'r') { |f| f.read }
				end
				
				@sites << Site.new(
					yaml_site['url'], 
					yaml_site['strip_html'] || true,
					yaml_site['notify'] || [],
					frefs,
					yaml_site['auth'] || {},
					cookie,
					yaml_site['check_interval'] || 5
				)
			end
			
			WCC.logger.debug @sites.length.to_s + (@sites.length == 1 ? ' site' : ' sites') + " loaded\n" +
				@sites.map { |s| "  #{s.uri.host.to_s}\n    url: #{s.uri.to_s}\n    id: #{s.id}" }.join("\n")
			
			@sites
		end
		
		def self.recipients
			return Conf.instance.recipients
		end
		
		def self.file(path = nil); File.join(self[:cache_dir], path) end
		def self.simulate?; self[:simulate] end
		def self.[](key); Conf.instance[key] end
		
		private
		
		def new_notificator(rec_name, not_name, opts, rec_out)
			klass = Notificators.mappings[not_name]
			if klass.nil?
				WCC.logger.error "Referenced notificator '#{not_name}' not found!"
				return
			end
			begin
				if opts.nil?; rec_out << klass.new
				else rec_out << klass.new(opts)
				end
			rescue => ex
				WCC.logger.error "Recipient '#{rec_name}' not notifiable via '#{not_name}' (skip): #{ex}"
			end
		end
	end
	
	class Notificators
		@@mappings = {}
		
		# API method - add a mapping from conf string to class object
		# @param [String] name the string to be used in conf.yml's conf entry
		# @param [Class] klass the associated notifier class
		def self.map(name, klass)
			WCC.logger.debug "Register notificator #{klass.inspect} for #{name}"
			@@mappings[name] = klass
		end
		
		def self.mappings; @@mappings end
	end

	class LogFormatter
		def initialize(use_color = true)
			@color = use_color
		end

		def white;  "\e[1;37m" end
		def cyan;   "\e[1;36m" end
		def magenta;"\e[1;35m" end
		def blue;   "\e[1;34m" end
		def yellow; "\e[1;33m" end
		def green;  "\e[1;32m" end
		def red;    "\e[1;31m" end
		def black;  "\e[1;30m" end
		def rst;    "\e[0m" end

		def call(lvl, time, progname, msg)
			text = "%s: %s" % [lvl, msg.to_s]
			if @color
				return [magenta, text, rst, "\n"].join if lvl == "FATAL"
				return [red, text, rst, "\n"].join if lvl == "ERROR"
				return [yellow, text, rst, "\n"].join if lvl == "WARN"
			end
			[text, "\n"].join
		end
	end
	
	class Prog
		def self.run!
			# make sure logger is correctly configured
			WCC.logger = Logger.new(STDOUT)
			# first use of Conf initializes it
			Conf.instance
			
			create_cache_dir
			clean_cache_dir if Conf[:clean]
			load_filters
			load_timestamps
			
			# stats
			@@stats = {
				'nruns' => 1,
				'nsites' => 0, 'nnotifications' => 0, 'nerrors' => 0,
				'nlines' => 0, 'nhunks' => 0
			}
			
			Conf.sites.each do |site|
				ts_old = get_timestamp(site)
				ts_new = Time.now.to_i
				if (ts_new-ts_old) < site.check_interval*60
					ts_diff = (ts_new-ts_old)/60
					WCC.logger.info "Skipping check for #{site.uri.host.to_s} due to check #{ts_diff} minute#{ts_diff == 1 ? '' : 's'} ago."
					next
				end
				case checkForUpdate(site)
				when :update
					WCC.logger.warn "#{site.uri.host.to_s} has an update!"
				when :noupdate
					WCC.logger.info "#{site.uri.host.to_s} is unchanged"
				when :error
					@@stats['nerrors'] += 1
				end
				update_timestamp(site, ts_new)
			end
			
			save_timestamps
			update_stats if Conf[:stats]
			shut_down_notificators
		end

		# Attempts to read the named template file from template.d
		# and converts it into ERB.
		#
		# @param [String] name file name of template file
		# @return [ERB] the ERB template or nil when file not found
		def self.load_template(name)
			t_path = File.join(Conf[:template_dir], name)
			if File.exists?(t_path)
				WCC.logger.debug "Load template '#{name}'"
				t = File.open(t_path, 'r') { |f| f.read }
				# <> omit newline for lines starting with <% and ending in %>
				return ERB.new(t, 0, "<>")
			end
			nil
		end

		# Attempts to write the given raw content to the named template file
		# in template.d. This should be used to create initial template files on demand
		# and will work only when file does not already exist.
		#
		# @param [String] name file name of template file
		# @param [String] raw_content content that should be written to template file
		def self.save_template(name, raw_content)
			t_path = File.join(Conf[:template_dir], name)
			if File.exists?(t_path)
				WCC.logger.warn "Trying to save template '#{name}' which already exists!"
				return
			end
			WCC.logger.info "Save template '#{name}' to #{t_path}"
			File.open(t_path, 'w') { |f| f.write(raw_content) }
		end
		
		# Central exit function, allows wcc a clean shutdown.
		def self.exit(errno)
			Kernel::exit errno
		end
		
		private
		
		def self.get_timestamp(site)
			@@timestamps[site.uri.to_s] || 0
		end
		
		def self.update_timestamp(site, t)
			@@timestamps[site.uri.to_s] = t
		end
		
		def self.create_cache_dir
			Dir.mkdir(Conf[:cache_dir]) unless File.directory?(Conf[:cache_dir])
		end

		def self.clean_cache_dir
			WCC.logger.warn "Removing hash and diff files..."
			Dir.foreach(Conf[:cache_dir]) do |f|
				File.delete(Conf.file(f)) if f =~ /^.*\.(md5|site)$/
			end
			# special files
			cache_file = Conf.file('cache.yml')
			WCC.logger.warn "Removing timestamp cache..."
			File.delete(cache_file) if File.exists?(cache_file)
			stats_file = Conf.file('stats.yml')
			WCC.logger.warn "Removing stats file..."
			File.delete(stats_file) if File.exists?(stats_file)
			Prog.exit 1
		end

		def self.load_filters
			Dir[File.join(Conf[:filter_dir], '*.rb')].each do |file|
				require file
			end
		end

		def self.load_timestamps
			cache_file = Conf.file('cache.yml')
			@@timestamps = {}
			if File.exists?(cache_file)
				WCC.logger.debug "Load timestamps from '#{cache_file}'"
				# may be *false* if file is empty
				yaml = YAML.load_file(cache_file)
				if not yaml
					WCC.logger.warn "No timestamps loaded"
				else
					@@timestamps = yaml['timestamps']
				end
			end
		end

		def self.save_timestamps
			cache_file = Conf.file('cache.yml')
			File.open(cache_file, 'w+') do |f| YAML.dump({"timestamps" => @@timestamps}, f) end
		end

		def self.update_stats
			stats_file = Conf.file('stats.yml')
			if File.exists?(stats_file)
				WCC.logger.debug "Load stats from '#{stats_file}'"
				yaml = YAML.load_file(stats_file)
				if not yaml
					WCC.logger.warn "No stats loaded"
				else
					# merge stats infos
					@@stats.each do |k,v| @@stats[k] += yaml['stats'][k] end
				end
			end
			File.open(stats_file, 'w+') do |f| YAML.dump({"stats" => @@stats}, f) end
		end

		def self.shut_down_notificators
			Notificators.mappings.each do |name,klass|
				WCC.logger.debug "Shut down #{klass}"
				klass.shut_down
			end
		end
		
		def self.checkForUpdate(site)
			WCC.logger.info "Requesting '#{site.uri.to_s}'"
			begin
				res = site.fetch
			rescue Timeout::Error => ex
				return :noupdate # don't claim on this
			rescue => ex
				WCC.logger.error "Cannot connect to #{site.uri.to_s} : #{ex.to_s}"
				return :error
			end
			return :error if handle_http_errors(res, site)
			
			new_content = get_utf8_body(res, site)
			return :error if new_content.nil?
			
			# strip html
			new_content = new_content.strip_html if site.strip_html?

			new_hash = Digest::MD5.hexdigest(new_content)
			WCC.logger.debug "Compare hashes\n  old: #{site.hash.to_s}\n  new: #{new_hash.to_s}"
			return :noupdate if new_hash == site.hash
			
			# do not try diff or anything if site was never checked before
			if site.new?
				site.hash, site.content = new_hash, new_content
				diff = nil # no diff possible
			else
				# save old site to tmp file
				old_site_file = Tempfile.open("wcc-#{site.id}-")
				old_site_file.write(site.content)
				old_site_file.close
				old_label = "OLD (%s)" % File.mtime(Conf.file(site.id + '.md5')).strftime(DIFF_TIME_FMT)
				new_label = "NEW (%s)" % Time.now.strftime(DIFF_TIME_FMT)
				# save new site
				site.hash, site.content = new_hash, new_content
				# diff between OLD and NEW
				diff = %x[diff -U 1 --label "#{old_label}" --label "#{new_label}" #{old_site_file.path} #{Conf.file(site.id + '.site')}]
			end

			# construct the data made available to filters and templates
			data = OpenStruct.new(:site => site, :tag => Conf[:tag],
				:diff => diff.nil? ? nil : WCC::Differ.new(diff))
			
			@@stats['nsites'] += 1
			if not data.diff.nil?
				@@stats['nlines'] += data.diff.nlinesc
				@@stats['nhunks'] += data.diff.nhunks
			end
			
			# HACK: there *was* an update but no notification is required
			return :noupdate if not Filters.accept(data, site.filters)
			
			site.notify.each do |name|
				rec = Conf.recipients[name]
				if rec.nil?
					WCC.logger.error "Could not notify recipient #{name} - not found!"
				else
					@@stats['nnotifications'] += 1
					rec.each { |way| way.notify!(data) }
				end
			end
			
			:update
		end

		def self.handle_http_errors(res, site)
			return false if res.kind_of?(Net::HTTPOK)
			if res.kind_of?(Net::HTTPMovedPermanently)
				loc = res['Location']
				if loc.nil?
					WCC.logger.error "Site #{site.uri.to_s} moved permanently, skipping it - no new location given."
				else
					WCC.logger.error "Site #{site.uri.to_s} moved permanently to '#{loc}', skipping it - please update your conf.yml adequately!"
				end
				return true
			elsif res.kind_of?(Net::HTTPSeeOther) or res.kind_of?(Net::HTTPTemporaryRedirect)
				loc = URI.parse(res['Location'])
				WCC.logger.warn "Redirect: requesting '#{loc.to_s}'"
				res = site.fetch_redirect(loc)
				if not res.kind_of?(Net::HTTPOK)
					WCC.logger.error "Redirected site #{loc.to_s} returned #{res.code} code, skipping it."
					WCC.logger.error "Headers: #{res.to_hash.inspect}"
					return true
				end
			elsif res.kind_of?(Net::HTTPUnauthorized)
				WCC.logger.error "Site #{site.uri.to_s} demands authentication for '#{res['www-authenticate']}', skipping it - consider using 'auth:' option in your conf.yml."
				return true
			elsif res.kind_of?(Net::HTTPNotFound)
				WCC.logger.error "Site #{site.uri.to_s} not found (404), skipping it."
				return true
			elsif res.kind_of?(Net::HTTPForbidden)
				WCC.logger.error "Site #{site.uri.to_s} forbids access (403), skipping it."
				return true
			elsif res.kind_of?(Net::HTTPInternalServerError)
				WCC.logger.error "Site #{site.uri.to_s} has internal errors (500), skipping it."
				return true
			elsif res.kind_of?(Net::HTTPServiceUnavailable)
				#retry_after = res['Retry-After']
				WCC.logger.warn "Site #{site.uri.to_s} currently not available (503), skipping it."
				return true
			else
				WCC.logger.error "Site #{site.uri.to_s} returned #{res.code} code, skipping it."
				WCC.logger.error "Headers: #{res.to_hash.inspect}"
				return true
			end
		end

		def self.get_utf8_body(res, site)
			# detect encoding from http header, meta element, default utf-8
			# do not use utf-8 regex because it will fail on non utf-8 pages
			encoding = (res['content-type'].to_s.match(/;\s*charset=([A-Za-z0-9-]*)/i).to_a[1] || 
						res.body.match(/<meta.*charset="?([a-zA-Z0-9-]*).*/i).to_a[1]).to_s.downcase || 'utf-8'
			WCC.logger.info "Encoding is '#{encoding}'"
			# convert to utf-8
			begin
				return Iconv.conv('utf-8', encoding, res.body)
			rescue => ex
				WCC.logger.error "Cannot convert site #{site.uri.to_s} from '#{encoding}': #{ex.to_s}"
			end
			nil
		end
	end
end
