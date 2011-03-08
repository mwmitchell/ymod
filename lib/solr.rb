module Ymod::Solr
  
  class << self
    
    attr_accessor :url
    
    def connection
      @connection ||= RSolr.connect(:url => self.url)
    end
    
    def with_connection &block
      yield connection
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
    
    def with_solr &block
      Ymod::Solr.with_connection &block
    end
    
    def default_solr_doc
      {
        :id => (@id || generate_id),
        :path => path,
        :source_path => source_path,
        :text => content,
        :type_name => type_name,
        :class_name => self.class.to_s,
        :created_at => "#{self.created_at.to_s}Z",
        :updated_at => "#{self.updated_at.to_s}Z"
      }
    end
    
    def to_solr
      default = default_solr_doc
      self.class.solr_mapping_block ?
        instance_eval(&self.class.solr_mapping_block).merge(default) :
        default
    end
    
    def destroy_solr_doc!
      with_solr { |c|
        c.delete_by_query "id:(#{@id})"
        c.commit
      }
    end
    
    def index_solr_doc!
      with_solr { |c|
        c.add to_solr
        c.commit
      }
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
      response = solr.select :params => params_for_find(query, params)
      response.extend SolrResponse
    end
    
    def params_for_find query, params = {}
      params["fq"] ||= []
      params["q"] ||= query
      tname_filter = "type_name:(#{type_name})"
      params["fq"] << tname_filter unless params["fq"].any?{|fq|fq == tname_filter}
      params
    end
    
    alias :all :find
    
    def find_by_id id, &block
      p = params_for_find_by_id(id)
      res = solr.select :params => p
      raise Ymod::RecordNotFoundError.new(id) if res["response"]["numFound"] == 0
      yield res if block_given?
      doc = res["response"]["docs"][0]
      instance = load doc["source_path"]
      instance.instance_variable_set "@id", doc["id"]
      instance
    end
    
    def params_for_find_by_id id
      {"q" => %Q(id:(#{id})), "rows" => 1}
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