require 'sinatra/base'

module Sinatra
  # Extension to reload modified files.  In the development
  # environment, it will automatically require files defining routes
  # with every incoming request, but you can refine the reloading
  # policy with +also_reload+ and +dont_reload+, to customize which
  # files should, and should not, be reloaded, respectively.
  module Reloader
    # Watches a file so it can tell when it has been updated.  It also
    # knows the routes defined and if it contains inline templates.
    class Watcher
      # Represents an element of a Sinatra application that needs to be
      # reloaded.
      #
      # Its +representation+ attribute is there to allow to identify the
      # element within an application, that is, to match it with its
      # Sinatra's internal representation.
      class Element < Struct.new(:type, :representation)
      end

      # Collection of file +Watcher+ that can be associated with a
      # Sinatra application.  That way, we can know which files belong
      # to a given application and which files have been modified.  It
      # also provides a mechanism to inform a Watcher the routes
      # defined in the file being watched, whether it has inline
      # templates and if it changes should be ignored.
      class List
        @app_list_map = Hash.new { |hash, key| hash[key] = new }

        # Returns (an creates if it doesn't exists) a +List+ for the
        # application +app+.
        def self.for(app)
          @app_list_map[app]
        end

        # Creates a new +List+ instance.
        def initialize
          @path_watcher_map = Hash.new do |hash, key|
            hash[key] = Watcher.new(key)
          end
        end

        # Lets the +Watcher+ for the file localted at +path+ know that the
        # +element+ is defined there, and adds the +Watcher+ to the +List+, if
        # it isn't already there.
        def watch(path, element)
          watcher_for(path).elements << element
        end

        # Tells the +Watcher+ for the file located at +path+ to ignore
        # the file changes, and adds the +Watcher+ to the +List+, if
        # it isn't already there.
        def ignore(path)
          watcher_for(path).ignore
        end

        # Adds a +Watcher+ for the file located at +path+ to the
        # +List+, if it isn't already there.
        def watcher_for(path)
          @path_watcher_map[File.expand_path(path)]
        end
        alias watch_file watcher_for

        # Returns an array with all the watchers in the +List+.
        def watchers
          @path_watcher_map.values
        end

        # Returns an array with all the watchers in the +List+ that
        # have been updated.
        def updated
          watchers.find_all(&:updated?)
        end
      end

      attr_reader :path, :elements, :mtime

      # Creates a new +Watcher+ instance for the file located at
      # +path+.
      def initialize(path)
        @path, @elements = path, []
        update
      end

      # Indicates whether or not the file being watched has been
      # modified.
      def updated?
        !ignore? && !removed? && mtime != File.mtime(path)
      end

      # Updates the file being watched mtime.
      def update
        @mtime = File.mtime(path)
      end

      # Indicates whether or not the file being watched has inline
      # templates.
      def inline_templates?
        elements.any? { |element| element.type == :inline_templates }
      end

      # Informs that the modifications to the file being watched
      # should be ignored.
      def ignore
        @ignore = true
      end

      # Indicates whether or not the modifications to the file being
      # watched should be ignored.
      def ignore?
        !!@ignore
      end

      # Indicates whether or not the file being watched has been
      # removed.
      def removed?
        !File.exist?(path)
      end
    end

    # When the extension is registed it extends the Sinatra
    # application +klass+ with the modules +BaseMethods+ and
    # +ExtensionMethods+ and defines a before filter to +perform+ the
    # reload of the modified file.
    def self.registered(klass)
      @reloader_loaded_in ||= {}
      return if @reloader_loaded_in[klass]

      @reloader_loaded_in[klass] = true

      klass.extend BaseMethods
      klass.extend ExtensionMethods
      klass.set(:reloader) { klass.development? }
      klass.set(:reload_templates) { klass.reloader? }
      klass.before do
        if klass.reloader?
          if Reloader.thread_safe?
            Thread.exclusive { Reloader.perform(klass) }
          else
            Reloader.perform(klass)
          end
        end
      end
    end

    # Reloads the modified files, adding, updating and removing routes
    # and inline templates as apporpiate.
    def self.perform(klass)
      Watcher::List.for(klass).updated.each do |watcher|
        klass.set(:inline_templates, watcher.path) if watcher.inline_templates?
        watcher.elements.each { |element| klass.deactivate(element) }
        $LOADED_FEATURES.delete(watcher.path)
        require watcher.path
        watcher.update
      end
    end

    # Indicates whether or not we can and need to run thread-safely.
    def self.thread_safe?
      Thread and Thread.list.size > 1 and Thread.respond_to?(:exclusive)
    end

    # Contains the methods defined in Sinatra::Base that are
    # overriden.
    module BaseMethods
      # Does everything Sinatra::Base#route does, but it also tells
      # the +Watcher::List+ for the Sinatra application to watch the
      # defined route.
      def route(verb, path, options={}, &block)
        source_location = block.respond_to?(:source_location) ?
          block.source_location.first : caller_files[1]
        signature = super
        watch_element(
          source_location, :route, { :verb => verb, :signature => signature }
        )
        signature
      end

      # Does everything Sinatra::Base#inline_templates= does, but it
      # also tells the +Watcher::List+ for the Sinatra application to
      # watch the inline templates in +file+ or the file who made the
      # call to his method.
      def inline_templates=(file=nil)
        file = (file.nil? || file == true) ?
          (caller_files[1] || File.expand_path($0)) : file
        watch_element(file, :inline_templates)
        super
      end

      # Does everything Sinatra::Base#use does, but it also tells the
      # +Watcher::List+ for the Sinatra application to watch the
      # middleware beign used.
      def use(middleware, *args, &block)
        path = caller_files[1] || File.expand_path($0)
        watch_element(path, :middleware, [middleware, args, block])
        super
      end

      # Does everything Sinatra::Base#add_filter does, but it also tells
      # the +Watcher::List+ for the Sinatra application to watch the
      # defined filter beign used.
      def add_filter(type, path = nil, options = {}, &block)
        source_location = block.respond_to?(:source_location) ?
          block.source_location.first : caller_files[1]
        result = super
        watch_element(source_location, :"#{type}_filter", filters[type].last)
        result
      end

      # Does everything Sinatra::Base#error does, but it also tells
      # the +Watcher::List+ for the Sinatra application to watch the
      # defined error handler.
      def error(*codes, &block)
        path = caller_files[1] || File.expand_path($0)
        result = super
        codes.each do |c|
          watch_element(path, :error, :code => c, :handler => @errors[c])
        end
        result
      end

      # Does everything Sinatra::Base#register does, but it also lets
      # the reloader know that an extension is beign registered, because
      # the elements defined in its +registered+ method need a special
      # treatment.
      def register(*extensions, &block)
        start_registering_extension
        result = super
        stop_registering_extension
        result
      end

      # Does everything Sinatra::Base#register does and then registers
      # the reloader in the +subclass+.
      def inherited(subclass)
        result = super
        subclass.register Sinatra::Reloader
        result
      end
    end

    # Contains the methods that the extension adds to the Sinatra
    # application.
    module ExtensionMethods
      # Removes the +element+ from the Sinatra application.
      def deactivate(element)
        case element.type
        when :route then
          verb      = element.representation[:verb]
          signature = element.representation[:signature]
          (routes[verb] ||= []).delete(signature)
        when :middleware then
          @middleware.delete(element.representation)
        when :before_filter then
          filters[:before].delete(element.representation)
        when :after_filter then
          filters[:after].delete(element.representation)
        when :error then
          code    = element.representation[:code]
          handler = element.representation[:handler]
          @errors.delete(code) if @errors[code] == handler
        end
      end

      # Indicates with a +glob+ which files should be reloaded if they
      # have been modified.  It can be called several times.
      def also_reload(glob)
        Dir[glob].each { |path| Watcher::List.for(self).watch_file(path) }
      end

      # Indicates with a +glob+ which files should not be reloaded
      # event if they have been modified.  It can be called several
      # times.
      def dont_reload(glob)
        Dir[glob].each { |path| Watcher::List.for(self).ignore(path) }
      end

    private

      attr_reader :register_path

      # Indicates an extesion is beign registered.
      def start_registering_extension
        @register_path = caller_files[2]
      end

      # Indicates the extesion has been registered.
      def stop_registering_extension
        @register_path = nil
      end

      # Indicates whether or not an extension is being registered.
      def registering_extension?
        !register_path.nil?
      end

      # Builds a Watcher::Element from +type+ and +representation+ and
      # tells the Watcher::List for the current application to watch it
      # in the file located at +path+.
      #
      # If an extension is beign registered, it also tells the list to
      # watch it in the file where the extesion has been registered.
      # This prevents the duplication of the elements added by the
      # extension in its +registered+ method with every reload.
      def watch_element(path, type, representation=nil)
        list = Watcher::List.for(self)
        element = Watcher::Element.new(type, representation)
        list.watch(path, element)
        list.watch(register_path, element) if registering_extension?
      end
    end
  end

  register Reloader
  Delegator.delegate :also_reload, :dont_reload
end
