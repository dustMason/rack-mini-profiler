require 'benchmark'
require 'json'
require 'timeout'

require "ruby-debug"

# TODO list
# DONE todo send all css files from StackExchange.Profiling.UI
# DONE need the "should I profile" option
# DONE Prefix needs to be configured
# DONE set long expiration header on files you server
# DONE at the end of the page, send a stub from MiniProfileHandler.cs
# DONE Set X-MiniProfilerID header, cache the results
# DONE Get json format from http://data.stackexchange.com/ last xhr request
# DONE implement benchmark method
# DONE override log_duration for sequel
# DONE cache cleanup

module Rack

	class MiniProfiler

		VERSION = 'rZlycOOTnzxZvxTmFuOEV0dSmu4P5m5bLrCtwJHVXPA='.freeze
		@@instance = nil

		def self.instance
			@@instance
		end

		def self.generate_id
			rand(36**20).to_s(36)
		end

		# Structs holding Page loading data
		# PageStruct
		#   ClientTimings: ClientTimerStruct
		#   Root: RequestTimer
		#     :has_many RequestTimer children
		#     :has_many SqlTimer children
		class ClientTimerStruct
			def initialize(env)
				@attributes = {}
			end

			def to_json(*a)
				@attributes.to_json(*a)
			end

			def init_from_form_data(env, page_struct)
				timings = []
				baseTime = page_struct['Started']
				formTime = env['rack.request.form_hash']['clientPerformance']['timing']
				timings.push({ "Name" => "Domain Lookup", 
					"Start" =>  formTime['domainLookupStart'].to_i - baseTime, 
					"Duration" => formTime['domainLookupEnd'].to_i - formTime['domainLookupStart'].to_i
				})
				timings.push( { "Name" => "Connect", 
					"Start" =>  formTime['connectStart'].to_i - baseTime, 
					"Duration" => formTime['connectEnd'].to_i - formTime['connectStart'].to_i
				})
				timings.push({ "Name" => "Request Start", 
					"Start" =>  formTime['requestStart'].to_i - baseTime, 
					"Duration" => -1
				})
				timings.push( { "Name" => "Response", 
					"Start" =>  formTime['responseStart'].to_i - baseTime, 
					"Duration" => formTime['responseEnd'].to_i - formTime['responseStart'].to_i
				})
				timings.push( { "Name" => "Unload Event", 
					"Start" =>  formTime['unloadEventStart'].to_i - baseTime, 
					"Duration" => formTime['unloadEventEnd'].to_i - formTime['unloadEventStart'].to_i
				})
				timings.push( { "Name" => "Dom Loading", 
					"Start" =>  formTime['domLoading'].to_i - baseTime, 
					"Duration" => -1
				})
				timings.push( { "Name" => "Dom Content Loaded Event", 
					"Start" =>  formTime['domContentLoadedEventStart'].to_i - baseTime, 
					"Duration" => formTime['domContentLoadedEventEnd'].to_i - formTime['domContentLoadedEventStart'].to_i
				})
				timings.push( { "Name" => "Dom Interactive", 
					"Start" =>  formTime['domInteractive'].to_i - baseTime, 
					"Duration" => -1
				})
				timings.push( { "Name" => "Load Event", 
					"Start" =>  formTime['loadEventStart'].to_i - baseTime, 
					"Duration" => formTime['loadEventEnd'].to_i - formTime['loadEventStart'].to_i
				})
				timings.push( { "Name" => "Dom Complete", 
					"Start" =>  formTime['domComplete'].to_i - baseTime, 
					"Duration" => -1
				})
				@attributes.merge!({
					"RedirectCount" => env['rack.request.form_hash']['clientPerformance']['navigation']['redirectCount'],
					"Timings" => timings
				})
			end
		end

		class SqlTimerStruct
			def initialize(query, duration_ms, page)
				@attributes = {
					"ExecuteType" => 3, # TODO
					"FormattedCommandString" => query,
					"StackTraceSnippet" => "No Stack Yet", # TODO
					"StartMilliseconds" => (Time.now.to_f * 1000).to_i - page['Started'],
					"DurationMilliseconds" => duration_ms,
					"FirstFetchDurationMilliseconds" => 0,
					"Parameters" => null,
					"ParentTimingId" => null,
					"IsDuplicate" => false
				}
			end

			def to_json(*a)
				@attributes.to_json(*a)
			end

			def []=(name, val)
				@attributes[name] = val
			end

			def [](name)
				@attributes[name]
			end
		end

		class RequestTimerStruct
			def self.createRoot(name, page)
				rt = RequestTimerStruct.new(name, page)
				rt["IsRoot"]= true
				rt
			end

			def initialize(name, page)
				@attributes = {
					"Id" => MiniProfiler.generate_id,
					"Name" => name,
					"DurationMilliseconds" => 0,
					"DurationWithoutChildrenMilliseconds"=> 0,
					"StartMilliseconds" => (Time.now.to_f * 1000).to_i - page['Started'],
					"ParentTimingId" => nil,
					"Children" => [],
					"HasChildren"=> false,
					"KeyValues" => nil,
					"HasSqlTimings"=> false,
					"HasDuplicateSqlTimings"=> false,
					"SqlTimings" => [],
					"SqlTimingsDurationMilliseconds"=> 0,
					"IsTrivial"=> false,
					"IsRoot"=> false,
					"Depth"=> 0,
					"ExecutedReaders"=> 0,
					"ExecutedScalars"=> 0,
					"ExecutedNonQueries"=> 0				
				}
				@children_duration = 0
			end
			
			def [](name)
				@attributes[name]
			end

			def []=(name, value)
				@attributes[name] = value
				self
			end

			def to_json(*a)
				@attributes.to_json(*a)
			end

			def add_child(request_timer)
				@attributes['Children'].push(request_timer)
				@attributes['HasChildren'] = true
				request_timer['ParentTimingId'] = @attributes['Id']
				request_timer['Depth'] = @attributes['Depth'] + 1
				@children_duration += request_timer['DurationMilliseconds']
			end

			def add_sql(query, elapsed_ms)
				timer = SqlTimerStruct.new(query, elapsed_ms)
				timer['ParentTimingId'] = @attributes['Id']
				@attributes['HasSqlTimings'] = true
				@attributes['SqlTimingsDurationMilliseconds'] += elapsed_ms
			end

			def record_benchmark(tms)
				@attributes['DurationMilliseconds'] = (tms.real * 1000).to_i
				@attributes['DurationWithoutChildrenMilliseconds'] = @attributes['DurationMilliseconds'] - @children_duration
 			end			
		end

		# MiniProfiles page, part of 
		class PageStruct
			def initialize(env)
				@attributes = {
					"Id" => MiniProfiler.generate_id,
					"Name" => env['PATH_INFO'],
					"Started" => (Time.now.to_f * 1000).to_i,
					"MachineName" => env['SERVER_NAME'],
					"Level" => 0,
					"User" => "unknown user",
					"HasUserViewed" => false,
					"ClientTimings" => ClientTimerStruct.new(env),
					"DurationMilliseconds" => 0,
					"HasTrivialTimings" => true,
					"HasAllTrivialTimigs" => false,
					"TrivialDurationThresholdMilliseconds" => 2,
					"Head" => nil,
					"DurationMillisecondsInSql" => 0,
					"HasSqlTimings" => true,
					"HasDuplicateSqlTimings" => false,
					"ExecutedReaders" => 3,
					"ExecutedScalars" => 0,
					"ExecutedNonQueries" => 1
				}
				name = "#{env['REQUEST_METHOD']} http://#{env['SERVER_NAME']}:#{env['SERVER_PORT']}#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
				@attributes['Root'] = RequestTimerStruct.createRoot(name, self)
			end

			def [](name)
				@attributes[name]
			end

			def []=(name, val)
				@attributes[name] = val
			end

			def to_json(*a)
				@attributes.merge( {
					"Started" => '/Date(%d)/' % @attributes['Started']
					}).to_json(*a)
			end
		end

		#
		# options:
		# :auto_inject - should script be automatically injected on every html page (not xhr)
		# :

		def initialize(app, options={})
			@@instance = self
			@options = {
				:auto_inject => true,	# automatically inject on every html page
				:base_url_path => "/mini-profiler-resources",
				:authorize_cb => lambda {|env| return true;} # callback returns true if this request is authorized to profile
			}.merge(options)
			@app = app
			@options[:base_url_path] += "/" unless @options[:base_url_path].end_with? "/"
			@timer_struct_cache = {}
		end

		def serve_results(env)
			request = Rack::Request.new(env)
			page_struct = @timer_struct_cache[request['id']]
			return [404, {} ["No such result #{request['id']}"]] unless page_struct
			unless page_struct['HasUserViewed']
				page_struct['ClientTimings'].init_from_form_data(env, page_struct)
				page_struct["HasUserViewed"] = true
			end
			[200, { 'Content-Type' => 'application/json'}, [page_struct.to_json]]
		end

		def serve_html(env)
			file_name = env['PATH_INFO'][(@options[:base_url_path].length)..1000]
			return serve_results(env) if file_name.eql?('results')
			full_path = ::File.expand_path("../html/#{file_name}", ::File.dirname(__FILE__))
			return [404, {}, ["Not found"]] unless ::File.exists? full_path
			f = Rack::File.new nil
			f.path = full_path
			f.cache_control = "max-age:86400"
			f.serving env
		end

		def add_to_timer_cache(page_struct)
			@timer_struct_cache[page_struct['Id']] = page_struct
		end

		EXPIRE_TIMER_CACHE = 3600 * 24 # expire cache in seconds

		def cleanup_cache
			puts "Cleaning up cache"
			expire_older_than = ((Time.now.to_f - MiniProfiler::EXPIRE_TIMER_CACHE) * 1000).to_i,
			@timer_struct_cache.delete_if { |k, v| v['Root']['StartMilliseconds'] < expire_older_than }
		end

		# clean up the cache every hour
		Thread.new do
			while true do
				MiniProfiler.instance.cleanup_cache if MiniProfiler.instance
				sleep(3600)
			end
		end

		def call(env)
			status = headers = body = nil
			env['profiler.mini'] = self

			# only profile if authorized
			return @app.call(env) unless @options[:authorize_cb].call(env)

			# handle all /mini-profiler requests here
 			return serve_html(env) if env['PATH_INFO'].start_with? @options[:base_url_path]

 			@inject_js = @options[:auto_inject] && (!env['HTTP_X_REQUESTED_WITH'].eql? 'XMLHttpRequest')

 			# profiling the request

 			@page_struct = PageStruct.new(env)
 			@current_timer = @page_struct["Root"]
			tms = Benchmark.measure do
				status, headers, body = @app.call(env)
			end
			@page_struct['Root'].record_benchmark tms

			# inject headers, script
			if status == 200
				add_to_timer_cache(@page_struct)
				# inject header
				headers['X-MiniProfilerID'] = @page_struct["Id"] if headers.is_a? Hash
				# inject script
				if @inject_js \
					&& headers.has_key?('Content-Type') \
					&& !headers['Content-Type'].match(/text\/html/).nil? then
					if (body.respond_to? :push)
						body.push(self.get_profile_script)
					elsif (body.is_a? String)
						body += self.get_profile_script
					else
						env['rack.logger'].error('could not attach mini-profiler to body, can only attach to Arrays and Strings')
					end
				end
			end
			@page_struct = @current_timer = nil
			[status, headers, body]
		end

		# get_profile_script returns script to be injected inside current html page
		# By default, profile_script is appended to the end of all html requests automatically.
		# Calling get_profile_script cancels automatic append for the current page
		# Use it when:
		# * you have disabled auto append behaviour throught :auto_inject => false flag
		# * you do not want script to be automatically appended for the current page. You can also call cancel_auto_inject
		def get_profile_script
			ids = [@page_struct["Id"]].to_s
			path = @options[:base_url_path]
			version = MiniProfiler::VERSION
			position = 'left'
			showTrivial = true
			showChildren = true
			maxTracesToShow = 15
			showControls = true
			currentId = @page_struct["Id"]
			authorized = true
			script = IO.read(::File.expand_path('../html/profile_handler.js', ::File.dirname(__FILE__)))
			# replace the variables
			[:ids, :path, :version, :position, :showTrivial, :showChildren, :maxTracesToShow, :showControls, :currentId, :authorized].each do |v|
				regex = Regexp.new("\\{#{v.to_s}\\}")
				script.gsub!(regex, eval(v.to_s).to_s)
			end
			# replace the '{{' and '}}''
			script.gsub!(/{{/, '{').gsub!(/}}/, '}')
			@inject_js = false
			script
		end

		# cancels automatic injection of profile script for the current page
		def cancel_auto_inject
			@inject_js = false
		end

		# benchmarks given block
		def benchmark(name, &b)
			old_timer = @current_timer
			@current_timer = RequestTimerStruct.new(name, @page_struct)
			@current_timer['Name'] = name
			tms = Benchmark.measure &b
			@current_timer.record_benchmark tms
			old_timer.add_child(@current_timer)
			@current_timer = old_timer
		end

		def record_sql(query, elapsed_ms)
			@current_timer.add_sql(query, elapsed_ms, @page_struct) if @current_timer
		end
	end

end
