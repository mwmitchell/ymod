module Ymod::Solr
  
  class << self
    attr_accessor :url
    def connection
      @connection ||= RSolr.connect(:url => self.url)
    end
  end
  
  def self.included base
    base.instance_eval do
      include InstanceMethods
      extend ClassMethods
      after_save lambda{|record|
        index_solr_doc!
      }
      after_destroy lambda{|record|
        destroy_solr_doc!
      }
    end
  end
  
  module InstanceMethods
    def to_solr
      default = {
        :id => (@id || generate_id),
        :path => path,
        :source_path => source_path,
        :text => content,
        :type_name => type_name,
        :class_name => self.class.to_s,
        :created_at => "#{self.created_at.to_s}Z",
        :updated_at => "#{self.updated_at.to_s}Z"
      }
      self.class.solr_mapping_block ?
        instance_eval(&self.class.solr_mapping_block).merge(default) :
        default
    end
    
    def destroy_solr_doc!
      Ymod::Solr.connection.delete_by_query("id:(#{@id})")
      Ymod::Solr.connection.commit
    end
    
    def index_solr_doc!
      Ymod::Solr.connection.add to_solr
      Ymod::Solr.connection.commit
    end
    
  end
  
  module ClassMethods
    
    attr_reader :solr_mapping_block
    
    def solr
      Ymod::Solr.connection
    end
    
    def solr_mapping &block
      @solr_mapping_block = block
    end
    
    def find query, params = {}
      params["fq"] ||= []
      params["q"] ||= query
      tname_filter = "type_name:(#{type_name})"
      params["fq"] << tname_filter unless params["fq"].any?{|fq|fq == tname_filter}
      response = solr.select :params => params
      response.extend SolrResponse
    end
    
    alias :all :find
    
    def find_by_id id
      res = solr.select :params => {"q" => %Q(id:(#{id})), "rows" => 1}
      yield res if block_given?
      doc = res["response"]["docs"][0]
      raise RecordNotFoundError.new(id) unless doc
      instance = load doc["source_path"]
      instance.instance_variable_set "@id", doc["id"]
      instance
    end
    
  end
  
  module SolrResponse
    def each_hit &block
      self["response"]["docs"].each do |d|
        klass = Kernel.const_get d["class_name"]
        instance = klass.load d["source_path"]
        instance.instance_variable_set "@id", d["id"]
        yield instance
      end
    end
  end
  
end