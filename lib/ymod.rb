require "rubygems"
require "rsolr"
require "active_model"
require "active_support/time"
require "stringex"
require "fileutils"

unless defined? Boolean
  class Boolean; end
end

module Ymod
  
  autoload :Solr, File.join(File.dirname(__FILE__), "solr")
  
  class << self
    attr_accessor :data_path
  end
  
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

  module Model
    
    attr_reader :id
    
    def self.included base
      base.instance_eval {
        extend ActiveModel::Naming
        extend ActiveModel::Callbacks
        include ActiveModel::Validations
        include ActiveModel::Serialization
        include ActiveModel::Conversion
        #
        extend Ymod::Loadable
        #
        # callbacks
        define_model_callbacks :save, :update, :destroy, :update_attributes, :initialize
        #
        # properties
        extend Properties::ClassMethods
        property :path, String
        property :content, String
        property :created_at, DateTime
        property :updated_at, DateTime
        #
        # timestamps
        before_save lambda { |record|
          @created_at ||= DateTime.now
          @updated_at = DateTime.now
        }
        #
        validates_presence_of :path
        #
        # solr support
        include Ymod::Solr
      }
    end
    
    def initialize attrs = {}
      _run_initialize_callbacks do
        update_attributes attrs
      end
    end
    
    def update_attributes attrs
      _run_update_attributes_callbacks do
        self.class.properties.each do |p|
          v = (attrs[p.name] || attrs[p.name.to_s])
          value = typed_value p, v
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
    
    def destroy!
      _run_destroy_callbacks do
        File.delete File.join(Ymod.data_path, source_path) if @id
      end
    end
    
    def save!
      _run_save_callbacks do
        raise RecordInvalidError.new(self) unless valid?
        yaml_data = to_hash{|k,v| [k.to_s, v]}
        content = yaml_data.delete "content"
        file_path = "#{Ymod.data_path}/#{type_name}s/#{path}"
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
    
    def update! attrs
      _run_update_callbacks do
        update_attributes attrs
        save
      end
    end
    
    def typed_value p, v
      case p.primitive.to_s
        when "DateTime"
          begin
            if Time === v
              v.to_datetime
            else
              DateTime.parse v unless v.nil?
            end
          rescue
            raise "#{self.class} @#{p.name}: #{v.inspect} couldn't be parsed by DateTime.parse"
          end
        when "String"
          v.to_s unless v.nil?
        when "Array"
          begin
            v.to_a unless v.nil?
          rescue
            "#{self.class} @#{p.name}: #{v.inspect} can't be converted to an Array"
          end
        when "Integer"
          v.to_i unless v.blank?
        when "Boolean"
          v.to_s == "true" ? true : false unless v.blank?
      else
        v
      end
    end
    
  end
  
  class Property
    attr_reader :name, :primitive
    def initialize name, primitive
      @name, @primitive = name, primitive
    end
  end
  
  module Properties
    
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
  
  module Loadable
    
    def load source_path
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