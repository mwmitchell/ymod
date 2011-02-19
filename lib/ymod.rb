require "rubygems"
require "active_model"
require "active_support/time"
require "rsolr"
require "stringex"

unless defined? Boolean
  class Boolean; end
end

# class Page
#   
#   include Ymod::Model
#   property :tags, Array
#   property :visible, Boolean
#   property :test, DateTime
#   
# end
# 
# p = Page.new(:path => "index.html", :tags => %W(one), :test => "2011-02-28")
# 
# begin
#   p.save
# rescue Ymod::RecordInvalidError
#   puts $!.record.errors.inspect
# rescue
#   puts p.created_at.month
# end

module Ymod
  
  class RecordNotFoundError < RuntimeError
    attr_reader :id
    def initialize id
      @id = id
    end
    def to_s
      "Record not found: #{@id}"
    end
  end
  
  class RecordInvalidError < RuntimeError
    attr_reader :record
    def initialize(record)
      @record = record
      super(@record.errors.full_messages.join(", "))
    end
  end
  
  class << self
    attr_accessor :solr_url, :data_path
    def solr
      @solr ||= RSolr.connect(:url => solr_url)
    end
  end
  
  module Model
    
    def self.included base
      base.extend ActiveModel::Naming
      base.extend ActiveModel::Callbacks
      base.send :include, ActiveModel::Validations
      base.send :include, ActiveModel::Serialization
      base.send :include, ActiveModel::Conversion
      base.send :include, Ymod::Properties
      base.send :include, Ymod::Findable
      base.extend Properties::ClassMethods
      base.define_model_callbacks :save, :update, :destroy, :update_attributes, :initialize
      #
      base.property :path, String
      base.property :content, String
      base.validates_presence_of :path
      base.before_save lambda{|record|
        @created_at ||= DateTime.now
        @updated_at = DateTime.now if @id
      }
      base.property :created_at, DateTime
      base.property :updated_at, DateTime
    end
    
    attr_reader :id
    
    def initialize attrs = {}
      _run_initialize_callbacks do
        update_attributes attrs
      end
    end
    
    def update_attributes attrs
      _run_update_attributes_callbacks do
        self.class.properties.each do |p|
          v = (attrs[p.name] || attrs[p.name.to_s])
          value = case p.primitive.to_s
            when "DateTime"
              begin
                DateTime.parse v unless v.nil?
              rescue
                raise "#{self.class} @#{p.name}: #{v.inspect} couldn't be parsed by DateTime.parse"
              end
            when "String"
              v.to_s
            when "Array"
              begin
                v.to_a
              rescue
                "#{self.class} @#{p.name}: #{v.inspect} can't be converted to an Array"
              end
            when "Integer"
              v.to_i
            when "Boolean"
              v.to_s == "true" ? true : false
            else
              v
            end
          instance_variable_set "@#{p.name}", value
        end
      end
    end
    
    alias :attributes= :update_attributes
    
    def generate_id
      source_path.to_url
    end

    def type_name
      self.class.type_name
    end

    def source_path
      "#{type_name}s/#{path}"
    end
    
    def to_hash &block
      out = {}
      self.class.properties.each do |p|
        k, v= p.name, instance_variable_get("@#{p.name}")
        k, v = yield(k,v) if block_given?
        out[k] = v
      end
      out
    end
    
    alias :attributes :to_hash
    
    def to_solr
      {
        :class_name => self.class.to_s,
        :id => (@id || generate_id),
        :path => path,
        :source_path => source_path,
        :text => content,
        :type_name => type_name
      }
    end
    
    def destroy
      _run_destroy_callbacks do
        if @id
          File.delete File.join(Ymod.data_path, source_path)
          Ymod.solr.delete_by_query("id:(#{@id})")
          Ymod.solr.commit
        end
      end
    end
    
    def save
      _run_save_callbacks do
        raise RecordInvalidError.new(self) unless valid?
        yaml_data = to_hash{|k,v| [k.to_s, v]}
        content = yaml_data.delete "content"
        self.class.solr.add to_solr
        self.class.solr.commit
        file_path = "data/#{type_name}s/#{path}"
        FileUtils.mkdir_p File.dirname(file_path)
        File.open(file_path, "w") do |f|
          f << yaml_data.to_yaml
          f << "---\n"
          f << content
        end
        @id = generate_id
        self
      end
    end
    
    def update attrs
      _run_update_callbacks do
        update_attributes attrs
        save
      end
    end
    
  end
  
  module Properties
    
    class Property
      attr_reader :name, :primitive
      def initialize name, primitive
        @name, @primitive = name, primitive
      end
    end
    
    module ClassMethods
      def type_name
        to_s.to_url
      end
      def properties
        @properties ||= []
      end
      def property name, primitive
        attr_accessor name
        properties << Property.new(name, primitive)
      end
    end
  end

  module Findable
    
    def self.included base
      base.extend ClassMethods
    end
    
    module ClassMethods
      
      def solr
        Ymod.solr
      end
      
      def all params = {}
        params["fq"] ||= []
        params["q"] ||= "*:*"
        tname_filter = "type_name:(#{type_name})"
        params["fq"] << tname_filter unless params["fq"].any?{|fq|fq == tname_filter}
        sresponse = solr.select :params => params
        yield sresponse if block_given?
        sresponse["response"]["docs"].map { |d|
          klass = Kernel.const_get d["class_name"]
          instance = klass.load_from_file d["source_path"]
          instance.instance_variable_set "@id", d["id"]
          instance
        }
      end
      
      def get id
        res = solr.select :params => {"q" => %Q(id:(#{id})), "rows" => 1}
        yield res if block_given?
        doc = res["response"]["docs"][0]
        raise RecordNotFoundError.new(id) unless doc
        instance = load_from_file doc["source_path"]
        instance.instance_variable_set "@id", doc["id"]
        instance
      end
      
      def load_from_file source_path
        full_path = "#{Ymod.data_path}/#{source_path}"
        raw = File.read(full_path)
        meta, content = parse_data raw
        new meta.merge(:content => content)
      end
      
      def parse_data raw
        fragments = raw.split(/^--- ?$/)[1..2]
        content = raw
        meta = {}
        if fragments.size > 1
          meta = fragments.shift
          content = fragments.shift
          meta = meta ? YAML.load(meta) : {}
        end
        [meta, content]
      end
      
    end
  end
end