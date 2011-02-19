require "rubygems"
require "active_model"
require "rsolr"
require "stringex"

module Ymod
  
  class RecordNotFound < RuntimeError
    attr_reader :id
    def initialize id
      @id = id
    end
    def to_s
      "Record not found: #{@id}"
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
      base.send :include, ActiveModel::Validations
      base.send :include, ActiveModel::Serialization
      base.send :include, Ymod::Properties
      base.send :include, Ymod::Findable
      base.extend Properties::ClassMethods
      base.property :path, String
      base.property :content, String
      base.validates_presence_of :path
    end
    
    def initialize attrs = {}
      self.class.properties.each do |p|
        instance_variable_set "@#{p.name}", (attrs[p.name] || attrs[p.name.to_s])
      end
    end
    
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
      if @id
        File.delete File.join(Ymod.data_path, source_path)
        Ymod.solr.delete_by_query("id:(#{@id})")
        Ymod.solr.commit
      end
    end
    
    def save
      raise "Invalid record" unless valid?
      yaml_data = to_hash{|k,v| [k.to_s, v]}
      content = yaml_data.delete "content"
      self.class.solr.add to_solr
      self.class.solr.commit
      File.open("data/#{type_name}s/#{path}", "w") do |f|
        f << yaml_data.to_yaml
        f << "---\n"
        f << content
      end
      self
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
        sresponse["response"]["docs"].map! { |d|
          klass = Kernel.const_get d["class_name"]
          instance = klass.load_from_file d["source_path"]
          instance.instance_variable_set "@id", d["id"]
          instance
        }
        sresponse
      end
      
      def get id
        res = solr.select :params => {:q => %Q(id:(#{id}))}
        doc = res["response"]["docs"][0]
        raise RecordNotFound.new(id) unless doc
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
        fragments = raw.split(/^--- ?\n.+/)
        content = raw
        meta = {}
        if fragments.size > 1
          fragments = raw.split(/^--- ?$/)[1..2]
          meta = fragments.shift
          content = fragments.shift
          meta = meta ? YAML.load(meta) : {}
        end
        [meta, content]
      end
      
    end
  end
end