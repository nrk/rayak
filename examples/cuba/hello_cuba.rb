# Cuba - http://github.com/soveran/cuba

require 'cuba'

Cuba.define do
    on get do
        on "hello" do
            res.write "Hello world!"
        end

        on true do
            res.redirect "/hello"
        end
    end
end
