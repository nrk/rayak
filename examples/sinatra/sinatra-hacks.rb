# temporary hack due to a bug in IronRuby when subclassing File, see
# http://ironruby.codeplex.com/WorkItem/View.aspx?WorkItemId=3895

module Sinatra::Helpers
    def send_file(path, opts={})
      stat = File.stat(path)
      last_modified stat.mtime

      content_type media_type(opts[:type]) ||
        media_type(File.extname(path)) ||
        response['Content-Type'] ||
        'application/octet-stream'

      response['Content-Length'] ||= (opts[:length] || stat.size).to_s

      if opts[:disposition] == 'attachment' || opts[:filename]
        attachment opts[:filename] || path
      elsif opts[:disposition] == 'inline'
        response['Content-Disposition'] = 'inline'
      end

      halt File.open(path, 'rb')
    rescue Errno::ENOENT
      not_found
    end

    class ::File
      alias_method :to_path, :path
      def each
        rewind
        while buf = read(8192)
          yield buf
        end
      end
    end
end