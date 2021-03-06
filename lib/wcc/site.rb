
module WCC
	class Site
		attr_reader :uri, :notify, :filters, :auth, :cookie, :check_interval, :id

		def initialize(url, strip_html, notify, filters, auth, cookie, check_interval)
			@uri = URI.parse(url)
			@strip_html = strip_html
			@notify = notify.is_a?(Array) ? notify : [notify]
			@filters = filters.is_a?(Array) ? filters : [filters]
			@auth = auth
			@cookie = cookie
			@check_interval = check_interval
			@id = Digest::MD5.hexdigest(url.to_s)[0...8]
			# invalid hashes are ""
			load_hash
		end

		def strip_html?; @strip_html end

		def new?
			hash.empty?
		end
		
		def load_hash
			file = Conf.file(@id + '.md5')
			if File.exists?(file)
				WCC.logger.debug "Load hash from file '#{file}'"
				File.open(file, 'r') { |f| @hash = f.gets; break }
			else
				WCC.logger.info "Site #{uri.host} was never checked before."
				@hash = ""
			end
		end
		
		def load_content
			file = Conf.file(@id + '.site')
			if File.exists?(file)
				File.open(file, 'r') { |f| @content = f.read }
			end
		end
		
		def hash; @hash end
		
		def hash=(hash)
			@hash = hash
			File.open(Conf.file(@id + '.md5'), 'w') { |f| f.write(@hash) } unless Conf.simulate?
		end
		
		def content; load_content if @content.nil?; @content end
		
		def content=(content)
			@content = content
			File.open(Conf.file(@id + '.site'), 'w') { |f| f.write(@content) } unless Conf.simulate?
		end

		def fetch
			retrieve(@uri)
		end

		def fetch_redirect(new_uri)
			retrieve(new_uri)
		end

		private

		def retrieve(uri)
			con = Net::HTTP.new(uri.host, uri.port)
			if uri.is_a?(URI::HTTPS)
				con.use_ssl = true
				con.verify_mode = OpenSSL::SSL::VERIFY_NONE
			end
			con.start do |http|
				#http.open_timeout = 20
				#http.read_timeout = 60
				req = Net::HTTP::Get.new(uri.request_uri)
				if @auth['type'] == 'basic'
					WCC.logger.debug "Doing basic auth"
					req.basic_auth(@auth['username'], @auth['password'])
				end
				if not @cookie.nil?
					req.add_field("Cookie", @cookie)
				end
				http.request(req)
			end
		end
	end
end
