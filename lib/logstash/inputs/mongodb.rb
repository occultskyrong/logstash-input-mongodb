# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/timestamp"
require "stud/interval"
require "socket" # for Socket.gethostname

# Generate a repeating message.
#
# This plugin is intented only as an example.

class LogStash::Inputs::MongoDB < LogStash::Inputs::Base
  config_name "mongodb"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "plain"

  # Example URI: mongodb://mydb.host:27017/mydbname?ssl=true
  config :uri, :validate => :string, :required => true

  # The path to the sqlite database file.
  config :path, :validate => :string, :required => true

  # Any table to exclude by name
  config :exclude_tables, :validate => :array, :default => []

  config :since_table, :validate => :string, :default => "logstash_since"

  # The collection to use. Should accept wildcard (i.e. 'events_*')
  # Example collection: events_20150227
  config :collection, :validate => :string, :required => true

  # If true, store the @timestamp field in mongodb as an ISODate type instead
  # of an ISO8601 string.  For more information about this, see
  # http://www.mongodb.org/display/DOCS/Dates
  config :isodate, :validate => :boolean, :default => false

  # Number of seconds to wait after failure before retrying
  config :retry_delay, :validate => :number, :default => 3, :required => false

  # If true, an "_id" field will be added to the document before insertion.
  # The "_id" field will use the timestamp of the event and overwrite an existing
  # "_id" field in the event.
  config :generateId, :validate => :boolean, :default => false

  # The message string to use in the event.
  config :message, :validate => :string, :default => "Hello World!"

  # Set how frequently messages should be sent.
  # The default, `1`, means send a message every second.
  config :interval, :validate => :number, :default => 1

  SINCE_TABLE = :since_table

  public
  def init_placeholder_table(sqlitedb)
    begin
      sqlitedb.create_table "#{SINCE_TABLE}" do
        String :table
        Int :place
      end
    rescue
      @logger.debug("since table already exists")
    end
  end

  public
  def get_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
    since = sqlitedb[SINCE_TABLE]
    x = since.where(:table => "#{since_table}_#{mongo_collection_name}")
    if x[:place].nil?
      init_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
      return 0
    else
      @logger.debug("placeholder already exists, it is #{x[:place]}")
      return x[:place][:place]
    end
  end

  public
  def init_placeholder(sqlitedb, since_table, mongodb, mongo_collection_name)
    @logger.debug("init placeholder for #{since_table}_#{mongo_collection_name}")
    since = sqlitedb[SINCE_TABLE]
    mongo_collection = mongodb.collection(mongo_collection_name)
    first_entry = mongo_collection.find_one({})
    first_entry_id = first_entry['_id'].to_s
    since.insert(:table => "#{since_table}_#{mongo_collection_name}", :place => first_entry_id)
  end

  public
  def update_placeholder(sqlitedb, since_table, mongo_collection_name, place)
    @logger.debug("set placeholder to #{place}")
    since = sqlitedb[SINCE_TABLE]
    since.where(:table => "#{since_table}_#{mongo_collection_name}").update(:place => place)
  end

  public
  def get_all_tables(mongodb)
    return @mongodb.collection_names
  end

  public
  def get_collection_names(mongodb)
    return @mongodb.collection_names
  end

  public
  def get_cursor_for_collection(mongodb, mongo_collection_name, last_id)
    collection = mongodb.collection(mongo_collection_name)
    return collection.find({:_id => {:$gt => last_id}})
  end

  public
  def register
    require "mongo"
    require "jdbc/sqlite3"
    require "sequel"
    uriParsed = Mongo::URIParser.new(@uri)
    conn = uriParsed.connection({})
    if uriParsed.auths.length > 0
      uriParsed.auths.each do |auth|
        if !auth['db_name'].nil?
          conn.add_auth(auth['db_name'], auth['username'], auth['password'], nil)
        end
      end
      conn.apply_saved_authentication()
    end
    @host = Socket.gethostname
    @logger.info("Registering MongoDB input", :database => @path)
    #@mongodb = conn.db(@database)
    @mongodb = conn.db(uriParsed.db_name)
    @sqlitedb = Sequel.connect("jdbc:sqlite:#{@path}")
    # Should check to see if there are new matching tables at a predefined interval or on some trigger
    @collections = get_collection_names(@mongodb)
    @collection_data = {}
    @collections.each do |collection|
      init_placeholder_table(@sqlitedb)
      last_id = get_placeholder(@sqlitedb, since_table, @mongodb, collection)
      @collection_data[collection] = { :name => collection, :last_id => last_id }
    end

  end # def register

  def run(queue)
    sleep_min = 0.01
    sleep_max = 5
    sleeptime = sleep_min

    begin
      @logger.debug("Tailing MongoDB", :path => @path)
      loop do
        @collection_data.each do |k, collection|
          collection_name = collection[:name]
          last_id = collection[:last_id]
          @logger.debug("last_id is #{last_id}", :k => k, :collection => collection_name)
          # get batch of events starting at the last_place if it is set
          last_id_object = BSON::ObjectId(last_id)
          cursor = get_cursor_for_collection(@mongodb, collection_name, last_id_object)
          @logger.debug("Mongo cursor is #{cursor}")
          cursor.each do |doc|
            @logger.debug("Parsing document #{doc}")
            event_id = doc['_id'].to_s
            @logger.debug("Event_id is: #{event_id}")
            date_time = DateTime.parse(doc['_id'].generation_time.to_s)
            #@timestamp = LogStash::Timestamp.new(date_time)
            event = LogStash::Event.new("host" => @host, "mongodb" => @mongodb)
            decorate(event)
            #event['@timestamp'] = LogStash::Timestamp.new(event_date)
            event["date_time"] = date_time.iso8601
            @logger.debug("Event date_time is: #{date_time.iso8601}")
            @logger.debug("Message will be: #{doc.to_s}")
            event["message"] = doc.to_s
            queue << event
            @logger.debug("k: #{k}")
            @logger.debug(":last_id: #{last_id}")
            @logger.debug("@table_data: #{@table_data}")
            @logger.debug("doc['_id]: #{doc['_id'].to_s}")
            @collection_data[k][last_id] = doc['_id'].to_s
          end
          # Store the last-seen doc in the database
          update_placeholder(@sqlitedb, since_table, collection_name, @collection_data[k][:last_id])
        end

        # nothing found in that iteration
        # sleep a bit
        @logger.debug("No new rows. Sleeping.", :time => sleeptime)
        sleeptime = [sleeptime * 2, sleep_max].min
        sleep(sleeptime)
        #sleeptime = sleep_min
      end
    end
  end # def run

end # class LogStash::Inputs::Example