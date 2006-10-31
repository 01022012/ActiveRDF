# Adapter to Redland database
# uses SPARQL for querying
#
# Author:: Eyal Oren
# Copyright:: (c) 2005-2006 Eyal Oren
# License:: LGPL
require 'active_rdf'
require 'federation/connection_pool'
require 'queryengine/query2sparql'
require 'rdf/redland'

# TODO: add json results for eric hanson

class RedlandAdapter < ActiveRdfAdapter
	$log.info "loading Redland adapter"
	ConnectionPool.register_adapter(:redland,self)
	
	# instantiate connection to Redland database
	def initialize(params = {})

    # TODO: check if the given file exists, or at least look for an exception from redland
		if params[:location] and params[:location] != :memory
			# setup file locations for redland database
			path, file = File.split(params[:location])
			type = 'bdb'
		else
			# fall back to in-memory redland 	
			type = 'memory'; path = '';	file = '.'
		end
		
		$log.info "RedlandAdapter: initializing with type: #{type} file: #{file} path: #{path}"
		
		@store = Redland::HashStore.new(type, file, path, false)
		@model = Redland::Model.new @store
	end	
	
	# load a file from the given location with the given syntax into the model.
	# use Redland syntax strings, e.g. "ntriples" or "rdfxml", defaults to "ntriples"
	def load(location, syntax="ntriples")
    $log.debug "Redland: loading file with syntax: #{syntax} and location: #{location}"
    parser = Redland::Parser.new(syntax, "", nil)
    parser.parse_into_model(@model, "file:#{location}")
	end
	
	# yields query results (as many as requested in select clauses) executed on data source
	def query(query)
		qs = Query2SPARQL.translate(query)
    $log.debug "RedlandAdapter: after translating to SPARQL, query is: #{qs}"
		
		time = Time.now
		clauses = query.select_clauses.size
		redland_query = Redland::Query.new(qs, 'sparql')
		query_results = @model.query_execute(redland_query)
		$log.debug "RedlandAdapter: query response from Redland took: #{Time.now - time}s"
		
		$log.debug "RedlandAdapter: query response has size: #{query_results.size}"

		# verify if the query has failed
		if query_results.nil?
		  $log.debug "RedlandAdapter: query has failed with nil result"
		  return false
		end
		if not query_results.is_bindings?
		  $log.debug "RedlandAdapter: query has failed without bindings"
		  return false
		end

		# convert the result to array
		#TODO: if block is given we should not parse all results into array first
		results = query_result_to_array(query_results) 
    $log.debug "RedlandAdapter: result of query is #{results.join(', ')}"
		
		if block_given?
			results.each do |clauses|
				yield(*clauses)
			end
		else
			results
		end
	end

	# executes query and returns results as SPARQL JSON or XML results
	# requires svn version of redland-ruby bindings
	# * query: ActiveRDF Query object
	# * result_format: :json or :xml
	def get_query_results(query, result_format=nil)
		get_sparql_query_results(Query2SPARQL.translate(query), result_format)
	end

	# executes sparql query and returns results as SPARQL JSON or XML results
	# * query: sparql query string
	# * result_format: :json or :xml
	def get_sparql_query_results(qs, result_format=nil)
		# author: Eric Hanson

		# set uri for result formatting
		result_uri = 
			case result_format
		 	when :json
        Redland::Uri.new('http://www.w3.org/2001/sw/DataAccess/json-sparql/')
      when :xml
        Redland::Uri.new('http://www.w3.org/TR/2004/WD-rdf-sparql-XMLres-20041221/')
			end

		# use sparql to query redland
		qs = Query2SPARQL.translate(query)

		# query redland
    redland_query = Redland::Query.new(qs, 'sparql')
    query_results = @model.query_execute(redland_query)

		# get string representation in requested result_format (json or xml)
    query_results.to_string()
  end
	
	# add triple to datamodel
	def add(s, p, o)
    $log.debug "adding triple #{s} #{p} #{o}"

		# verify input
		if s.nil? || p.nil? || o.nil?
      $log.debug "cannot add triple with empty subject, exiting"
		  return false
		end 
		
		unless s.respond_to?(:uri) && p.respond_to?(:uri)
      $log.debug "cannot add triple where s/p are not resources, exiting"		
		  return false
		end
	
		begin
		  @model.add(wrap(s), wrap(p), wrap(o))		  
			save if ConnectionPool.auto_flush?
		rescue Redland::RedlandError => e
		  $log.warn "RedlandAdapter: adding triple failed in Redland library: #{e}"
		  return false
		end		
	end

	# saves updates to the model into the redland file location
	def save
		Redland::librdf_model_sync(@model.model).nil?
	end
	alias flush save
	
	def reads?
		true
	end
	
	def writes?
		true
	end
	
	# returns size of datasources as number of triples
	#
	# warning: expensive method as it iterates through all statements
	def size
		# we cannot use @model.size, because redland does not allow counting of 
		# file-based models (@model.size raises an error if used on a file)
		
		# instead, we just dump all triples, and count them
		stats = []
    @model.statements{|s,p,o| stats << [s,p,o]}
		stats.size
	end
	
	################ helper methods ####################
	#TODO: if block is given we should not parse all results into array first
	def query_result_to_array(query_results)
	 	results = []
	 	number_bindings = query_results.binding_names.size
	 	
	 	# walk through query results, and construct results array
	 	# by looking up each result (if it is a resource) and adding it to the result-array
	 	# for literals we only add the values
	 	
	 	# redland results are set that needs to be iterated
	 	while not query_results.finished?
	 		# we collect the bindings in each row and add them to results
	 		results << (0..number_bindings-1).collect do |i|	 		
	 			# node is the query result for one binding
	 			node = query_results.binding_value(i)

				# we determine the node type
 				if node.literal?
 					# for literal nodes we just return the value
 					node.to_s
 				elsif node.blank?
 				  # blank nodes we ignore
 				  nil
			  else
 				 	# other nodes are rdfs:resources
 					RDFS::Resource.new(node.uri.to_s)
	 			end
	 		end
	 		# iterate through result set
	 		query_results.next
	 	end
	 	results
	end	 	
	
	def wrap node
		case node
		when RDFS::Resource
			Redland::Uri.new(node.uri)
		else
			Redland::Literal.new(node.to_s)
		end
	end
end
