#!/usr/bin/env ruby
#encoding: UTF-8

require 'bundler/setup'
Bundler.require(:default)

require	'rubygems'
require 'sinatra'
require 'tire'
require 'rex'
require 'resque/server'
require './importer'

CRYPT = Rex::Proto::NTLM::Crypt

configure do
	set :public_folder, Proc.new { File.join(root, "static") }
	set :per_page, 25
end

def generate_hashes(password)

	lm = CRYPT.lm_hash(password).unpack("H*")[0]
	return lm
end

helpers do
	Tire.configure do
		elasurl = File.open("elastic.conf").first
		url("#{elasurl.chomp}/")
	end

	Tire.index 'connectivitytest' do
		delete
		create
		store :title => 'One',   :tags => ['ruby'],           :published_on => '2011-01-01'
		store :title => 'Two',   :tags => ['ruby', 'python'], :published_on => '2011-01-02'
		delete
	end

	Tire.index 'whitechapel-hashes' do

		# REMOVE THIS DELETE
		#delete

		create :mappings => {
			:document => {
			  :properties => {
					:password  => { :type => 'string', :index => 'not_analyzed', :include_in_all => false },
					:hash      => { :type => 'string', :analyzer => 'snowball'  },
					:type     => { :type => 'string'}
				}
			}
		}
=begin
		hashforhell = generate_hashes('hello world')
		document = [
			{:password => 'hello world', :hash => '5eb63bbbe01eeed093cb22bb8f5acdc3', :hashtype => 'md5', :type => 'document'},
			{:password => 'hello world', :hash => "#{hashforhell}", :hashtype => 'lm', :type => 'document'},
			{:password => 'password', :hash => '5f4dcc3b5aa765d61d8327deb882cf99', :hashtype => 'md5', :type => 'document'}
		]

		import document
=end
	end
end


def parse_file(filedata)
	lines = filedata.split("\n") #split out file into separate lines
	lines.collect! {|x| x.chomp } # deal with Windows' stupid \r\n
	return lines
end

def parse_pwdump(lines)
	results = {}
	results['found'] = []
	results['unknown'] = []
	lines.delete_if {|x| x =~ /^((?!:::).)*$/ }
	lines.each do |line|
		parts = line.split(':')
		if parts.size == 4
			if parts[2].upcase != 'AAD3B435B51404EEAAD3B435B51404EE' then

				lm = Tire.search( 'whitechapel-hashes' ) do |search|
					search.query { |query| query.string "hash:#{parts[2]}" }
				end
				lm.filter :terms, :hashtype => ["lm"]

				if lm.results.size > 0 then
					results['found'] << {'username' => parts[0], 'password' => lm.results[0]['password'], 'hash' => parts[2], 'hashtype' => 'lm' }
				else
					results['unknown'] << {'username' => parts[0], 'hash' => parts[2], 'hashtype' => 'lm' }
				end
			end

			ntlm = Tire.search( 'whitechapel-hashes' ) do |search|
				search.query { |query| query.string "hash:#{parts[3]}" }
			end
			ntlm.filter :terms, :hashtype => ["ntlm"]

			if ntlm.results.size > 0 then
				results['found'] << {'username' => parts[0], 'password' => ntlm.results[0]['password'], 'hash' => parts[3], 'hashtype' => 'ntlm' }
			else
				results['unknown'] << {'username' => parts[0], 'hash' => parts[3], 'hashtype' => 'ntlm' }
			end
		end
	end
	puts 'Finished parsing pwdump file'
	return results
end

get '/' do
	# puts @s.to_curl

	erb :index
end

get '/search/pass' do
	q = params[:q].to_s !~ /\S/ ? '*' : params[:q].to_s
	f = params[:p].to_i*settings.per_page

	#pipe = Fifo.new('que.fifo', :w, :nowait)
	#puts q
	#pipe.puts "#{q}"

	Resque.enqueue(EnqueuePasswords, q)

	@s = Tire.search( 'whitechapel-hashes' ) do |search|
		search.query { |query| query.string "password:\"#{q}\"" }
		search.size settings.per_page
		search.from f
	end

	erb :search
end

get '/search/hash' do
	h = params[:h].to_s !~ /\S/ ? '*' : params[:h].to_s
	f = params[:p].to_i*settings.per_page

	@s = Tire.search( 'whitechapel-hashes' ) do |search|
		search.query { |query| query.string "hash:#{h}" }
		search.size settings.per_page
		search.from f
	end

	erb :search
end

# Handle GET-request (Show the upload form)
get "/upload" do
  erb :upload
end

post "/upload/dictionary" do
	wordlist = []
	dictionaryfile = params['dictionary'][:tempfile].read
	lines = parse_file(dictionaryfile)
	lines.each do |word|
		Resque.enqueue(EnqueuePasswords, word.force_encoding('UTF-8'))
	end
	@error = "File added to import queue.."
	erb :upload
end

# Handle POST-request (Receive and save the uploaded file)
post "/upload/pwdump" do
	pwdumpoutput = params['pwdump'][:tempfile].read
	lines = parse_file(pwdumpoutput)
	@results = parse_pwdump(lines)
	erb :uploadprocessing
end

post "/upload/shadowfile" do

	@error = "Feature not finished yet..."
	erb :upload
end







# john ./johnfile.txt --show=LEFT --format=NT
