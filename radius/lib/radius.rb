module Radius
  # Abstract base class for all parsing errors.
  class ParseError < StandardError
  end
  
  # Occurs when Parser cannot find an end tag for a given tag in a template or when
  # tags are miss-matched in a template.
  class MissingEndTagError < ParseError
    # Create a new MissingEndTagError object for +tag_name+. 
    def initialize(tag_name)
      super("end tag not found for start tag `#{tag_name}'")
    end
  end
  
  # Occurs when Context#render_tag cannot find the specified tag on a Context.
  class UndefinedTagError < ParseError
    # Create a new MissingEndTagError object for +tag_name+. 
    def initialize(tag_name)
      super("undefined tag `#{tag_name}'")
    end
  end
  
  module TagDefinitions # :nodoc:
    class TagFactory # :nodoc:
      def initialize(context)
        @context = context
      end
      
      def define_tag(name, options, &block)
        options = prepare_options(name, options)
        validate_params(name, options, &block)
        construct_tag_set(name, options, &block)
        expose_methods_as_tags(name, options)
      end
      
      protected

        # Adds the tag definition to the context. Override in subclasses to add additional tags
        # (child tags) when the tag is created.
        def construct_tag_set(name, options, &block)
          @context.set_item_for(name, options[:for]) if options[:for]
          if block
            @context.definitions[name.to_s] = block
          else
            @context.define_tag(name) do |tag|
              if tag.single?
                tag.item
              else
                tag.expand
              end
            end
          end
        end

        # Normalizes options pased to tag definition. Override in decendants to preform
        # additional normalization.
        def prepare_options(name, options)
          options = Util.symbolize_keys(options)
          options[:expose] = expand_array_option(options[:expose])
          object = options[:for]
          options[:attributes] = object.respond_to?(:attributes) unless options.has_key? :attributes
          options[:expose] += object.attributes.keys if options[:attributes]
          options
        end
        
        # Validates parameters passed to tag definition. Override in decendants to add custom
        # validations.
        def validate_params(name, options, &block)
          unless options.has_key? :for
            raise ArgumentError.new("tag definition must contain a :for option or a block") unless block
            raise ArgumentError.new("tag definition must contain a :for option when used with the :expose option") unless options[:expose].empty?
          end
        end
        
        # Exposes the methods of an object as child tags.
        def expose_methods_as_tags(name, options)
          options[:expose].each do |method|
            tag_name = "#{name}:#{method}"
            @context.define_tag(tag_name) do |tag|
              object = tag.item_for(name)
              object.send(method)
            end
          end
        end
        
      protected
      
        def expand_array_option(value)
          [*value].compact.map { |m| m.to_s.intern }
        end
    end
    
    class EnumerableTagFactory < TagFactory # :nodoc:
      protected
        def construct_tag_set(name, options, &block) 
          super
          
          @context.define_tag "#{name}:size" do |tag|
            object = tag.item_for(name)
            object.entries.size
          end
      
          @context.define_tag "#{name}:count" do |tag|
            tag.context.render_tag "#{name}:size"
          end
      
          @context.define_tag "#{name}:length" do |tag|
            tag.context.render_tag "#{name}:size"
          end
      
          item_tag_name = "#{name}:each:#{options[:item_tag]}"
      
          @context.define_tag "#{name}:each" do |tag|
            object = tag.item_for(name)
            result = []
            object.each do |item|
              tag.set_item_for(item_tag_name, item)
              result << tag.expand
            end 
            result
          end
      
          @context.define_tag(item_tag_name, :for => nil, :expose => options[:item_expose]) do |tag|
            tag.item
          end
          
          options[:expose_as_items] += ['min', 'max']
          expose_items(name, options)
        end
        
        def prepare_options(name, options)
          options = super
          options[:item_tag] = (options.has_key?(:item_tag) ? options[:item_tag] : 'item').to_s
          options[:item_expose] = expand_array_option(options[:item_expose])
          options[:expose_as_items] = expand_array_option(options[:expose_as_items])
          options
        end
        
        def expose_items(name, options)
          options[:expose_as_items].each do |exposer|
            @context.define_tag "#{name}:#{exposer}" do |tag|
              object = tag.item_for(name)
              tag.item = object.send(exposer)
              if tag.single?
                tag.item
              else
                tag.expand
              end
            end
          
            options[:item_expose].each do |method|
              @context.define_tag "#{name}:#{exposer}:#{method}" do |tag|
                object = tag.item_for("#{name}:#{exposer}") || tag.item_for(name).send(exposer)
                object.send(method) if object
              end
            end
          end
        end
    end
    
    class CollectionTagFactory < EnumerableTagFactory # :nodoc:
      protected
        def construct_tag_set(name, options, &block)
          options[:expose_as_items] += [:first, :last]
          super
        end
    end
  end
  
  #
  # A tag binding is passed into each tag definition and contains helper methods for working
  # with tags. Use it to gain access to the attributes that were passed to the tag, to
  # render the tag contents, and to do other tasks.
  #
  class TagBinding
    # The Context that the TagBinding is associated with. Used internally. Try not to use
    # this object directly.
    attr_accessor :context
    
    # The name of the tag (as used in a template string).
    attr_reader :name
    
    # The attributes of the tag. Also aliased as TagBinding#attr.
    attr_reader :attributes
    alias :attr :attributes
    
    # The render block. When called expands the contents of the tag. Use TagBinding#expand
    # instead.
    attr_reader :block
    
    # Creates a new TagBinding object.
    def initialize(name, attributes, &block)
      @name, @attributes, @block = name, attributes, block
    end
    
    # Evaluates the current tag and returns the rendered contents.
    def expand
      double? ? block.call : ''
    end

    # Returns true if the current tag is a single tag.
    def single?
      block.nil?
    end

    # Returns true if the current tag is a double tag.
    def double?
      not single?
    end
    
    # Returns the item associated with the current tag.
    def item
      item_for(@name)
    end
    
    # Associates an item with the current tag.
    def item=(value)
      set_item_for(@name, value)
    end
    
    # Gets the item associated with another tag.
    def item_for(tag_name)
      @context.item_for_tag(tag_name)
    end
    
    # Sets the item associated with another tag.
    def set_item_for(tag_name, value)
      @context.set_item_for(tag_name, value)
    end
    
    # Returns a list of the way tags are nested around the current tag as a string.
    def nesting
      @context.current_nesting
    end
    
    # Fires off Context#tag_missing for the curren tag.
    def missing!
      @context.tag_missing(name, attributes, &block)
    end
    
    # Using the context render the tag.
    def render(tag, attributes = {}, &block)
      @context.render_tag(tag, attributes, &block)
    end
  end
  
  #
  # A context contains the tag definitions which are available for use in a template.
  #
  class Context
    # A hash of tag definition blocks that define tags accessible on a Context.
    attr_accessor :definitions # :nodoc:
    
    # Creates a new Context object.
    def initialize(&block)
      @definitions = {}
      @tag_binding_stack = []
      @items_for_tags = {}
      with(&block) if block_given?
    end
    
    # Yeild an instance of self for tag definitions:
    #
    #   context.with do |c|
    #     c.define_tag 'test' do
    #       'test'
    #     end
    #   end
    #
    def with
      yield self
      self
    end
    
    # Creates a tag definition on a context. Several options are available to you
    # when creating a tag:
    # 
    # +for+::             Specifies an object that the tag is in reference to. This is
    #                     applicable when a block is not passed to the tag, or when the
    #                     +expose+ option is also used.
    #
    # +expose+::          Specifies that child tags should be set for each of the methods
    #                     contained in this option. May be either a single symbol/string or
    #                     an array of symbols/strings.
    #
    # +attributes+::      Specifies whether or not attributes should be exposed
    #                     automatically. Useful for ActiveRecord objects. Boolean. Defaults
    #                     to +true+.
    #
    # +expose_as_items+:: Specifies a list of items (strings or symbols) which refer to
    #                     methods that return items (only applical when the type option
    #                     is set to 'enumerable' or 'collection').
    #
    # +item_tag+::        Specifies the name of the item tag (only applicable when the type
    #                     option is set to 'enumerable' or 'collection').
    #
    # +item_expose+::     Works like +expose+ except that it exposes methods on items
    #                     referenced by tags with a type of 'enumerable' or 'collection'.
    #
    # +type+::            When this option is set to 'enumerable' the following additional
    #                     tags are added as child tags: +each+, <tt>each:item</tt>, +max+, 
    #                     +min+, +size+, +length+, and +count+. When set to 'collection'
    #                     all of the 'enumerable' child tags are added along with +first+
    #                     and +last+. Value may be specified as a string or symbol.
    #
    def define_tag(name, options = {}, &block)
      type = Util.impartial_hash_delete(options, :type).to_s
      klass = Util.constantize('Radius::TagDefinitions::' + Util.camelize(type) + 'TagFactory') rescue raise(ArgumentError.new("Undefined type `#{type}' in options hash"))
      klass.new(self).define_tag(name, options, &block)
    end

    # Returns the value of a rendered tag. Used internally by Parser#parse.
    def render_tag(name, attributes = {}, &block)
      tag_definition_block = @definitions[qualified_tag_name(name.to_s)]
      if tag_definition_block
        stack(name, attributes, block) do |tag|
          tag_definition_block.call(tag).to_s
        end
      else
        tag_missing(name, attributes, &block)
      end
    end

    # Like method_missing for objects, but fired when a tag is undefined.
    # Override in your own Context to change what happens when a tag is
    # undefined. By default this method raises an UndefinedTagError.
    def tag_missing(name, attributes, &block)
      raise UndefinedTagError.new(name)
    end

    # Each tag is allowed to associate a single variable with itself.
    # This method returns the item associated with a tag.
    def item_for_tag(name)
      n = qualified_tag_name(name)
      @items_for_tags[n]
    end
    
    # Each tag is allowed to associate a single variable with itself.
    # This method sets that variable.
    def set_item_for(name, value)
      n = qualified_tag_name(name)
      @items_for_tags[n] = value
    end

    # Returns the state of the current render stack. Useful from inside
    # a tag definition. Normally just use TagBinding#nesting.
    def current_nesting
      @tag_binding_stack.collect { |tag| tag.name }.join(':')
    end

    private

      # A convienence method for managing the various parts of the
      # tag binding stack.
      def stack(name, attributes, block)
        binding = TagBinding.new(name, attributes, &block)
        binding.context = self
        @tag_binding_stack.push(binding)
        result = yield(binding)
        @tag_binding_stack.pop
        result
      end

      # Returns a fully qualified tag name based on state of the
      # tag binding stack.
      def qualified_tag_name(name)
        n = name
        loop do
          tag_name = scan_stack_for_tag_name(n)
          return tag_name if tag_name
          break unless n =~ /^(.*?):(.*)$/
          n = $2
        end
        name
      end
      
      def scan_stack_for_tag_name(name)
        names = @tag_binding_stack.collect { |tag| tag.name }.join(':').split(':')
        loop do
          try = (names + [name]).join(':')
          return try if @definitions.has_key? try
          break unless names.size > 0
          names.pop
        end
        nil
      end
  end

  class ParseTag # :nodoc:
    def initialize(&b)
      @block = b
    end

    def on_parse(&b)
      @block = b
    end

    def to_s
      @block.call(self)
    end
  end

  class ParseContainerTag < ParseTag # :nodoc:
    attr_accessor :name, :attributes, :contents
    
    def initialize(name = "", attributes = {}, contents = [], &b)
      @name, @attributes, @contents = name, attributes, contents
      super(&b)
    end
  end

  #
  # The Radius parser. Initialize a parser with a Context object that
  # defines how tags should be expanded.
  #
  class Parser
    # The Context object used to expand template tags.
    attr_accessor :context
    
    # The string that prefixes all tags that are expanded by a parser
    # (the part in the tag name before the first colon).
    attr_accessor :tag_prefix
    
    # Creates a new parser object initialized with a Context.
    def initialize(context = Context.new, options = {})
      if context.kind_of?(Hash) and options.empty?
        options = context
        context = options[:context] || options['context'] || Context.new
      end
      options = Util.symbolize_keys(options)
      @context = context
      @tag_prefix = options[:tag_prefix]
    end

    # Parse string for tags, expand them, and return the result.
    def parse(string)
      @stack = [ParseContainerTag.new { |t| t.contents.to_s }]
      pre_parse(string)
      @stack.last.to_s
    end

    protected

      def pre_parse(text)
        re = %r{<#{@tag_prefix}:([\w:]+?)(\s+(?:\w+\s*=\s*(["']).*?\3\s*)*|)>|</#{@tag_prefix}:([\w:]+?)\s*>}
        if md = re.match(text)
          start_tag, attr, end_tag = $1, $2, $4
          @stack.last.contents << ParseTag.new { parse_individual(md.pre_match) }
          remaining = md.post_match
          if start_tag
            parse_start_tag(start_tag, attr, remaining)
          else
            parse_end_tag(end_tag, remaining)
          end
        else
          if @stack.length == 1
            @stack.last.contents << ParseTag.new { parse_individual(text) }
          else
            raise MissingEndTagError.new(@stack.last.name)
          end
        end
      end

      def parse_start_tag(start_tag, attr, remaining) # :nodoc:
        @stack.push(ParseContainerTag.new(start_tag, parse_attributes(attr)))
        pre_parse(remaining)
      end

      def parse_end_tag(end_tag, remaining) # :nodoc:
        popped = @stack.pop
        if popped.name == end_tag
          popped.on_parse { |t| @context.render_tag(popped.name, popped.attributes) { t.contents.to_s } }
          tag = @stack.last
          tag.contents << popped
          pre_parse(remaining)
        else
          raise MissingEndTagError.new(popped.name)
        end
      end

      def parse_individual(text) # :nodoc:
        re = %r{<#{@tag_prefix}:([\w:]+?)(\s+(?:\w+\s*=\s*(["']).*?\3\s*)*|)/>}
        if md = re.match(text)
          attr = parse_attributes($2)
          replace = @context.render_tag($1, attr)
          md.pre_match + replace + parse_individual(md.post_match)
        else
          text || ''
        end
      end

      def parse_attributes(text) # :nodoc:
        attr = {}
        re = /(\w+?)\s*=\s*('|")(.*?)\2/
        while md = re.match(text)
          attr[$1] = $3
          text = md.post_match
        end
        attr
      end
  end

  module Util # :nodoc:
    def self.symbolize_keys(hash)
      new_hash = {}
      hash.keys.each do |k|
        new_hash[k.to_s.intern] = hash[k]
      end
      new_hash
    end
    
    def self.impartial_hash_delete(hash, key)
      string = key.to_s
      symbol = string.intern
      value1 = hash.delete(symbol)
      value2 = hash.delete(string)
      value1 || value2
    end
    
    def self.constantize(camelized_string)
      raise "invalid constant name `#{camelized_string}'" unless camelized_string.split('::').all? { |part| part =~ /^[A-Za-z]+$/ }
      Object.module_eval(camelized_string)
    end
    
    def self.camelize(underscored_string)
      string = ''
      underscored_string.split('_').each { |part| string << part.capitalize }
      string
    end
  end
  
end