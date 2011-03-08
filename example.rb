require File.join(File.dirname(__FILE__), "lib", "ymod")

Ymod.data_path = "./data"
Ymod::Solr.url = "http://127.0.0.1:8983/solr/ymod"

# Ymod::Solr.with_connection {|c|
#   c.delete_by_query("*:*")
#   c.commit
# }

class Page
  include Ymod::Model
  property :title, String
  property :tags, Array
  validates_presence_of :title
  solr_mapping {{
    :tags => tags,
    :title => title
  }}
end

page = Page.new(:path => "index", :title => "-.-- --.-", :tags => ["cq", "morse"])
#page = Page.load("pages/index")
#page = Page.find_by_id("pages-slash-index")

begin
  page.save!
rescue Ymod::RecordInvalidError
  puts $!.record.errors.inspect
  exit
end

res = Page.find("*:*", :fq => "tags:morse")

res.each_hit { |rec|
  puts rec.inspect
  date = "#{rec.created_at.year}/#{rec.created_at.month}/#{rec.created_at.day}"
  puts "#{date}: #{rec.title}"
}