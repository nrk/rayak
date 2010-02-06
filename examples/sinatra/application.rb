require 'rubygems'
require 'rayak'
require 'sinatra'
require 'sinatra-hacks'
require 'haml'

set :server, 'kayak'

helpers do
    def dwn_dir; File.join(Dir.pwd, 'downloads'); end
end

get '/' do
    haml :index
end

post '/hello' do
    haml :nice_to_meet_you, :locals => { 
        :name  => params[:name],
        :files => Dir.entries(dwn_dir).reject{ |item| File.directory? item },
    }
end

get '/download/:filename' do
    send_file(
        File.join(dwn_dir, params[:filename]), :disposition => 'attachment'
    )
end


__END__
@@ layout
%html
  %head
    %title Testing Rayak with Sinatra
    %meta{:"http-equiv"=>"Content-Type", :content=>"text/html; charset=utf-8" }
  %body
    =yield


@@ index
%p Basic Sinatra application running on the Kayak HTTP server with Rayak
%p
  %form(method="post" action="./hello")
    %label(for="your_name")
      Insert you name here
    %input(id="your_name" name="name" type="text")
    %input(type="submit" value="... and now let me know you!")


@@ nice_to_meet_you
%p Oh, so your name is #{name}. Well, nice to meet you!
%p
  Here is a list of files that you can download:
  %ul
    - files.each do |file|
      %li
        %a(href="../download/#{file}") #{file}