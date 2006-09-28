# maintains pool of adapter instances that are connected to datasources
# returns right adapter for a given datasource, by either reusing 
# existing adapter-instance or creating new adapter-instance
require 'singleton'
class ConnectionPool
	include Singleton
	
	# adapters-classes known to the pool, registered by the adapter-class 
	# itself using register_adapter method, used to select new 
	# adapter-instance for requested connection type
	@@registered_adapter_types = Hash.new

	def initialize
		clear
	end

	# clears the pool: removes all registered data sources
	def clear
	 # pool of all adapters
		@@adapter_pool = []

    # pool of connection parameters to all adapter
		@@adapter_parameters = []
		@write_adapter = nil
	end
	
	# returns the set of currently registered read-access datasources
	def read_adapters
		reads = @@adapter_pool.select {|adapter| adapter.reads? }
	end
	
	# returns the currently selected data source for write-access
	def write_adapter
		@@write_adapter
	end
	
	# sets the given adapter as currently selected writeable adapter
	# (sets currently selected writer to nil if given adapter does not support writing)
	def write_adapter= adapter
		@@write_adapter = adapter.writes? ? adapter : nil
	end

	# returns adapter-instance for given parameters (either existing or new)
	def add_data_source(connection_params)
		# either get the adapter-instance from the pool 
		# or create new one (and add it to the pool)
		index = @@adapter_parameters.index(connection_params)
		if index.nil?
		  # adapter not in the pool yet: create it,
		  # register its connection parameters in parameters-array
		  # and add it to the pool (at same index-position as parameters)
		  adapter = create_adapter(connection_params)
		  @@adapter_parameters << connection_params
		  @@adapter_pool << adapter
      adapter
		else
		  # if adapter parametrs registered already,
		  # then adapter must be in the pool, at the same index-position as its parameters
		  @@adapter_pool[index]
		end
	end
	
	# adapter-types can register themselves with connection pool by 
	# indicating which adapter-type they are
	def register_adapter(type, klass)
		@@registered_adapter_types[type] = klass
	end
	
	private
	# create new adapter from connection parameters
	def create_adapter connection_params
		# lookup registered adapter klass
		klass = @@registered_adapter_types[connection_params[:type]]
		
		# raise error if adapter type unknown
		raise(ActiveRdfError, "unknown adapter type #{connection_params[:type]}") if klass.nil?
		
		# create new adapter-instance
		klass.send(:new,connection_params)
	end
end