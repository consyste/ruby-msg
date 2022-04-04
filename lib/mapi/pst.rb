#
# = Introduction
#
# This file is mostly an attempt to port libpst to ruby, and simplify it in the process. It
# will leverage much of the existing MAPI => MIME conversion developed for Msg files, and as
# such is purely concerned with the file structure details.
#
# = TODO
# 
# 1. solve recipient table problem (test4).
#    this is done. turns out it was due to id2 clashes. find better solution
# 2. check parse consistency. an initial conversion of a 30M file to pst, shows
#    a number of messages conveting badly. compare with libpst too.
# 3. xattribs
# 4. generalise the Mapi stuff better
# 5. refactor index load
# 6. msg serialization?
#

=begin

quick plan for cleanup.

have working tests for 97 and 03 file formats, so safe.

want to fix up:

64 bit unpacks scattered around. its ugly. not sure how best to handle it, but am slightly tempted
to override String#unpack to support a 64 bit little endian unpack (like L vs N/V, for Q). one way or
another need to fix it. Could really slow everything else down if its parsing the unpack strings twice,
once in ruby, for every single unpack i do :/

the index loading process, and the lack of shared code between normal vs 64 bit variants, and Index vs Desc.
should be able to reduce code by factor of 4. also think I should move load code into the class too. then
maybe have something like:

class Header
	def index_class
		version_2003 ? Index64 : Index
	end
end

def load_idx
	header.index_class.load_index
end

OR

def initialize
	@header = ...
	extend @header.index_class::Load
	load_idx
end

need to think about the role of the mapi code, and Pst::Item etc, but that layer can come later.

=end

require 'mapi'
require 'ostruct'
require 'ole/ranges_io'
require 'mapi/helper'

module Mapi
# Read Outlook's pst file
class Pst
	class FormatError < StandardError
	end

	# unfortunately there is no Q analogue which is little endian only.
	# this translates T as an unsigned quad word, little endian byte order, to
	# not pollute the rest of the code.
	#
	# didn't want to override String#unpack, cause its too hacky, and incomplete.
	#
	# @param str [String]
	# @param unpack_spec [String]
	# @return [Array]
	# @private
	def self.unpack str, unpack_spec
		return str.unpack(unpack_spec) unless unpack_spec['T']
		@unpack_cache ||= {}
		t_offsets, new_spec = @unpack_cache[unpack_spec]
		unless t_offsets
			t_offsets = []
			offset = 0
			new_spec = ''
			unpack_spec.scan(/([^\d])_?(\*|\d+)?/o) do
				num_elems = $1.downcase == 'a' ? 1 : ($2 || 1).to_i
				if $1 == 'T'
					num_elems.times { |i| t_offsets << offset + i }
					new_spec << "V#{num_elems * 2}"
				else
					new_spec << $~[0]
				end
				offset += num_elems
			end
			@unpack_cache[unpack_spec] = [t_offsets, new_spec]
		end
		a = str.unpack(new_spec)
		t_offsets.each do |offset|
			low, high = a[offset, 2]
			a[offset, 2] = low && high ? low + (high << 32) : nil
		end
		a
	end

	# @param str [String]
	# @param size [Integer]
	# @param count [Integer]
	# @return [Array<String>]
	# @private
	def self.split_per str, size, count
		count = str.length / size if count < 0
		list = []
		count.times {|i| list << str[size * i, size]}
		list
	end

	#
	# this is the header and encryption encapsulation code
	# ----------------------------------------------------------------------------
	#

	# class which encapsulates the pst header
	#
	# @private
	class Header
		SIZE = 512
		MAGIC = 0x2142444e

		# these are the constants defined in libpst.c, that
		# are referenced in pst_open()
		INDEX_TYPE_OFFSET = 0x0A
		FILE_SIZE_POINTER = 0xA8
		FILE_SIZE_POINTER_64 = 0xB8
		SECOND_POINTER = 0xBC
		INDEX_POINTER = 0xC4
		SECOND_POINTER_64 = 0xE0
		INDEX_POINTER_64 = 0xF0
		ENC_OFFSET = 0x1CD

		# @return [Integer]
		attr_reader :magic
		# @return [Integer]
		attr_reader :index_type
		# @return [Integer]
		attr_reader :encrypt_type
		# @return [Integer]
		attr_reader :size
		# @return [Integer]
		attr_reader :block_btree_count
		# @return [Integer]
		attr_reader :block_btree
		# @return [Integer]
		attr_reader :node_btree_count
		# @return [Integer]
		attr_reader :node_btree
		# @return [Integer]
		attr_reader :version
		
		def initialize data
			@magic = data.unpack('N')[0]
			@index_type = data[INDEX_TYPE_OFFSET].ord
			@version = {0x0e => 1997, 0x17 => 2003, 0x24 => 2003}[@index_type]

			if version_2003?
				# don't know?
				# >> data1.unpack('V*').zip(data2.unpack('V*')).enum_with_index.select { |(c, d), i| c != d and not [46, 56, 60].include?(i) }.select { |(a, b), i| b == 0 }.map { |(a, b), i| [a / 256, i] }
				#   [8, 76], [32768, 84], [128, 89]
				# >> data1.unpack('C*').zip(data2.unpack('C*')).enum_with_index.select { |(c, d), i| c != d and not [184..187, 224..227, 240..243].any? { |r| r === i } }.select { |(a, b), i| b == 0 and ((Math.log(a) / Math.log(2)) % 1) < 0.0001 }
				#   [[[2, 0], 61], [[2, 0], 76], [[2, 0], 195], [[2, 0], 257], [[8, 0], 305], [[128, 0], 338], [[128, 0], 357]]
				# i have only 2 psts to base this guess on, so i can't really come up with anything that looks reasonable yet. not sure what the offset is. unfortunately there is so much in the header
				# that isn't understood...
				@encrypt_type = 1

				@node_btree_count, @node_btree = Pst.unpack(data[SECOND_POINTER_64 - 8, 16], "T2")
				@block_btree_count, @block_btree = Pst.unpack(data[INDEX_POINTER_64  - 8, 16], "T2")

				@size = data[FILE_SIZE_POINTER_64, 4].unpack('V')[0]
			else
				@encrypt_type = data[ENC_OFFSET].ord

				@node_btree_count, @node_btree = data[SECOND_POINTER - 4, 8].unpack('V2')
				@block_btree_count, @block_btree = data[INDEX_POINTER  - 4, 8].unpack('V2')

				@size = data[FILE_SIZE_POINTER, 4].unpack('V')[0]
			end

			validate!
		end

		# return `true` if pst is an Unicode version. Unicode version also uses 64-bit file pointer.
		# otherwise return `false` where pst is an ANSI version. ANSI version uses 32-bit file pointer.
		#
		# @return [Boolean]
		def version_2003?
			version == 2003
		end

		def encrypted?
			encrypt_type != 0
		end

		def validate!
			raise FormatError, "bad signature on pst file (#{'0x%x' % magic})" unless magic == MAGIC
			raise FormatError, "only index types 0x0e, 0x17 and 0x24 are handled (#{'0x%x' % index_type})" unless [0x0e, 0x17, 0x24].include?(index_type)
			raise FormatError, "only encrytion types 0 and 1 are handled (#{encrypt_type.inspect})" unless [0, 1].include?(encrypt_type)
		end
	end

	# compressible encryption! :D
	#
	# simple substitution. see libpst.c
	# maybe test switch to using a String#tr!
	#
	# @private
	class CompressibleEncryption
		DECRYPT_TABLE = [
			0x47, 0xf1, 0xb4, 0xe6, 0x0b, 0x6a, 0x72, 0x48,
			0x85, 0x4e, 0x9e, 0xeb, 0xe2, 0xf8, 0x94, 0x53, # 0x0f
			0xe0, 0xbb, 0xa0, 0x02, 0xe8, 0x5a, 0x09, 0xab,
			0xdb, 0xe3, 0xba, 0xc6, 0x7c, 0xc3, 0x10, 0xdd, # 0x1f
			0x39, 0x05, 0x96, 0x30, 0xf5, 0x37, 0x60, 0x82,
			0x8c, 0xc9, 0x13, 0x4a, 0x6b, 0x1d, 0xf3, 0xfb, # 0x2f
			0x8f, 0x26, 0x97, 0xca, 0x91, 0x17, 0x01, 0xc4,
			0x32, 0x2d, 0x6e, 0x31, 0x95, 0xff, 0xd9, 0x23, # 0x3f
			0xd1, 0x00, 0x5e, 0x79, 0xdc, 0x44, 0x3b, 0x1a,
			0x28, 0xc5, 0x61, 0x57, 0x20, 0x90, 0x3d, 0x83, # 0x4f
			0xb9, 0x43, 0xbe, 0x67, 0xd2, 0x46, 0x42, 0x76,
			0xc0, 0x6d, 0x5b, 0x7e, 0xb2, 0x0f, 0x16, 0x29, # 0x5f
			0x3c, 0xa9, 0x03, 0x54, 0x0d, 0xda, 0x5d, 0xdf,
			0xf6, 0xb7, 0xc7, 0x62, 0xcd, 0x8d, 0x06, 0xd3, # 0x6f
			0x69, 0x5c, 0x86, 0xd6, 0x14, 0xf7, 0xa5, 0x66,
			0x75, 0xac, 0xb1, 0xe9, 0x45, 0x21, 0x70, 0x0c, # 0x7f
			0x87, 0x9f, 0x74, 0xa4, 0x22, 0x4c, 0x6f, 0xbf,
			0x1f, 0x56, 0xaa, 0x2e, 0xb3, 0x78, 0x33, 0x50, # 0x8f
			0xb0, 0xa3, 0x92, 0xbc, 0xcf, 0x19, 0x1c, 0xa7,
			0x63, 0xcb, 0x1e, 0x4d, 0x3e, 0x4b, 0x1b, 0x9b, # 0x9f
			0x4f, 0xe7, 0xf0, 0xee, 0xad, 0x3a, 0xb5, 0x59,
			0x04, 0xea, 0x40, 0x55, 0x25, 0x51, 0xe5, 0x7a, # 0xaf
			0x89, 0x38, 0x68, 0x52, 0x7b, 0xfc, 0x27, 0xae,
			0xd7, 0xbd, 0xfa, 0x07, 0xf4, 0xcc, 0x8e, 0x5f, # 0xbf
			0xef, 0x35, 0x9c, 0x84, 0x2b, 0x15, 0xd5, 0x77,
			0x34, 0x49, 0xb6, 0x12, 0x0a, 0x7f, 0x71, 0x88, # 0xcf
			0xfd, 0x9d, 0x18, 0x41, 0x7d, 0x93, 0xd8, 0x58,
			0x2c, 0xce, 0xfe, 0x24, 0xaf, 0xde, 0xb8, 0x36, # 0xdf
			0xc8, 0xa1, 0x80, 0xa6, 0x99, 0x98, 0xa8, 0x2f,
			0x0e, 0x81, 0x65, 0x73, 0xe4, 0xc2, 0xa2, 0x8a, # 0xef
			0xd4, 0xe1, 0x11, 0xd0, 0x08, 0x8b, 0x2a, 0xf2,
			0xed, 0x9a, 0x64, 0x3f, 0xc1, 0x6c, 0xf9, 0xec  # 0xff
		]

		ENCRYPT_TABLE = [nil] * 256
		DECRYPT_TABLE.each_with_index { |i, j| ENCRYPT_TABLE[i] = j }

		def self.decrypt_alt encrypted
			decrypted = ''
			encrypted.length.times { |i| decrypted << DECRYPT_TABLE[encrypted[i]] }
			decrypted
		end

		def self.encrypt_alt decrypted
			encrypted = ''
			decrypted.length.times { |i| encrypted << ENCRYPT_TABLE[decrypted[i]] }
			encrypted
		end

		# an alternate implementation that is possibly faster....
		# TODO - bench
		DECRYPT_STR, ENCRYPT_STR = [DECRYPT_TABLE, (0...256)].map do |values|
			values.map { |i| i.chr }.join.gsub(/([\^\-\\])/, "\\\\\\1")
		end

		def self.decrypt encrypted
			encrypted.tr ENCRYPT_STR, DECRYPT_STR
		end

		def self.encrypt decrypted
			decrypted.tr DECRYPT_STR, ENCRYPT_STR
		end
	end

	# @return [IO]
	# @private
	attr_reader :io

	# @return [Header]
	# @private
	attr_reader :header

	# @return [Array<BlockPtr>]
	# @private
	attr_reader :blocks

	# @return [Array<NodePtr>]
	# @private
	attr_reader :nodes

	# @return [Hash<Integer, Symbol>]
	# @private
	attr_reader :special_folder_ids

	# @return [Helper]
	# @private
	attr_reader :helper

	# @param io [IO]
	# @param helper [Helper,nil]
	def initialize io, helper=nil
		# corresponds to
		# * pst_open
		# * pst_load_index

		@io = io
		io.pos = 0
		@helper = helper || Helper.new
		@header = Header.new io.read(Header::SIZE)

		# would prefer this to be in Header#validate, but it doesn't have the io size.
		# should perhaps downgrade this to just be a warning...
		raise FormatError, "header size field invalid (#{header.size} != #{io.size}}" unless header.size == io.size

		load_block_btree
		load_node_btree
		load_xattrib

		@special_folder_ids = {}
	end

	# @return [Boolean]
	# @private
	def encrypted?
		@header.encrypted?
	end

	# until i properly fix logging...
	#
	# @private
	def warn s
		Mapi::Log.warn s
	end

	#
	# this is the index and desc record loading code
	# ----------------------------------------------------------------------------
	#

	# @private
	ToTree = Module.new

	# more constants from libpst.c
	# these relate to the index block
	# @private
	ITEM_COUNT_OFFSET = 0x1f0 # count byte

	# @private
	LEVEL_INDICATOR_OFFSET = 0x1f3 # node or leaf

	# @private
	BACKLINK_OFFSET = 0x1f8 # backlink u1 value

	# these 3 classes are used to hold various file records

	# pst_index
	#
	# @private
	class BlockPtr < Struct.new(:id, :offset, :size, :u1)
		UNPACK_STR32 = 'VVvv'
		UNPACK_STR64 = 'TTvv'
		SIZE32 = 12
		SIZE64 = 24
		BLOCK_SIZE = 512 # index blocks was 516 but bogus
		COUNT_MAX32 = 41 # max active items (ITEM_COUNT_OFFSET / Index::SIZE = 41)
		COUNT_MAX64 = 20 # bit of a guess really. 512 / 24 = 21, but doesn't leave enough header room

		# @return [Pst]
		attr_accessor :pst

		# @param data [String, Array]
		# @param is64 [Boolean]
		def initialize data, is64
			data = Pst.unpack data, (is64 ? UNPACK_STR64 : UNPACK_STR32) if String === data
			super(*data)
		end

		# @return [Symbol]
		def type
			@type ||= begin
				if id & 0x2 == 0
					:data
				else
					first_byte, second_byte = read.unpack('CC')
					if first_byte == 1
						raise second_byte unless second_byte == 1
						:data_chain_header
					elsif first_byte == 2
						raise second_byte unless second_byte == 0
						:id2_assoc
					else
						raise FormatError, 'unknown first byte for block - %p' % first_byte
					end
				end
			end
		end

		# @return [Boolean]
		def data?
			(id & 0x2) == 0
		end

		# @return [String]
		def read decrypt=true
			# only data blocks are every encrypted
			decrypt = false unless data?
			pst.pst_read_block_size offset, size, decrypt
		end

		# show all numbers in hex
		def inspect
			super.gsub(/=(\d+)/) { '=0x%x' % $1.to_i }.sub(/Index /, "Index type=#{type.inspect}, ")
		end
	end

	# mostly guesses.

	# @private
	ITEM_COUNT_OFFSET_64 = 0x1e8

	# @private
	LEVEL_INDICATOR_OFFSET_64 = 0x1eb # diff of 3 between these 2 as above...

	# _pst_table_ptr_struct
	#
	# @private
	class TablePtr < Struct.new(:start, :u1, :offset)
		UNPACK_STR32 = 'V3'
		UNPACK_STR64 = 'T3'
		SIZE32 = 12
		SIZE64 = 24

		# @param data [String]
		# @param is64 [Boolean]
		def initialize data, is64
			data = Pst.unpack(data, is64 ? UNPACK_STR64 : UNPACK_STR32) if String === data
			super(*data)
		end
	end

	# pst_desc
	# idx_id is a pointer to an idx record which gets the primary data stream for the Desc record.
	# idx2_id gets you an idx record, that when read gives you an ID2 association list, which just maps
	# another set of ids to index values
	#
	# @private
	class NodePtr < Struct.new(:node_id, :block_id, :sub_block_id, :parent_node_id)
		UNPACK_STR32 = 'V4'
		UNPACK_STR64 = 'T3V'
		SIZE32 = 16
		SIZE64 = 32
		BLOCK_SIZE = 512 # descriptor blocks was 520 but bogus
		COUNT_MAX64 = 15
		COUNT_MAX32 = 31 # max active desc records (ITEM_COUNT_OFFSET / Desc::SIZE = 31)

		include ToTree

		# @return [Pst]
		attr_accessor :pst

		# @return [Array]
		attr_reader :children

		# @param data [String]
		# @param is64 [Boolean]
		def initialize data, is64
			super(*Pst.unpack(data, is64 ? UNPACK_STR64 : UNPACK_STR32))
			@children = []
		end

		# @return [BlockPtr]
		def block
			raise "DO NOT USE"
			pst.block_from_id block_id
		end

		# @return [BlockPtr]
		def sub_block
			raise "DO NOT USE"
			pst.block_from_id sub_block_id
		end

		# Read node data
		#
		# @return [Array<String>]
		def read_main_array
			@read_main ||= begin
				list = []
				pst.load_node_main_data_to node_id, list
				list
			end
		end

		# Locate and read node sub data by its local id
		#
		# @param local_node_id [Integer]
		# @return [Array<String>]
		def read_sub_array local_node_id
			list = []
			pst.load_node_sub_data_to node_id, local_node_id, list
			list
		end

		# @return [Array<String>]
		def get_local_node_list
			list = []
			pst.get_local_node_list_to node_id, list
			list
		end

		# Check if there is a sub data exists, where it is identified by its local id
		#
		# @param local_node_id [Integer]
		# @return [Boolean]
		def has_sub local_node_id
			#TODO fixme
			read_sub_array(local_node_id).length != 0
		end

		# show all numbers in hex
		def inspect
			super.gsub(/=(\d+)/) { '=0x%x' % $1.to_i }
		end
	end

	# corresponds to
	# * _pst_build_id_ptr
	#
	# @private
	def load_block_btree
		@blocks = []
		@block_offsets = []
		load_block_tree header.block_btree, header.block_btree_count, 0

		# we'll typically be accessing by id, so create a hash as a lookup cache
		@block_from_id = {}
 		@blocks.each do |idx|
			id = idx.id & ~1
			warn "there are duplicate idx records with id #{id}" if @block_from_id[id]
			@block_from_id[id] = idx
		end
	end

	# load the flat idx table, which maps ids to file ranges. this is the recursive helper
	#
	# corresponds to
	# * _pst_build_id_ptr
	#
	# @private
	def load_block_tree offset, linku1, start_val
		@block_offsets << offset

		#_pst_read_block_size(pf, offset, BLOCK_SIZE, &buf, 0, 0) < BLOCK_SIZE)
		buf = pst_read_block_size offset, BlockPtr::BLOCK_SIZE, false

		item_count = buf[is64 ? ITEM_COUNT_OFFSET_64 : ITEM_COUNT_OFFSET].ord
		level = buf[is64 ? LEVEL_INDICATOR_OFFSET_64 : LEVEL_INDICATOR_OFFSET].ord
		count_max = is64 ? BlockPtr::COUNT_MAX64 : BlockPtr::COUNT_MAX32
		raise "have too many active items in index (#{item_count})" if item_count > count_max

		this_node_id = is64 ? Pst.unpack(buf[BACKLINK_OFFSET, 8], "T").first : buf[BACKLINK_OFFSET, 4].unpack("V").first
		raise 'blah 1' unless this_node_id == linku1

		if level == 0
			# leaf pointers
			size = is64 ? BlockPtr::SIZE64 : BlockPtr::SIZE32

			# split the data into item_count index objects
			Pst.split_per(buf, size, item_count).each_with_index do |data, i|
				idx = BlockPtr.new data, is64
				# first entry
				raise 'blah 3' if i == 0 and start_val != 0 and idx.id != start_val
				idx.pst = self
				# this shouldn't really happen i'd imagine
				raise "OHNO" if idx.id == 0
				@blocks << idx
			end
		else
			# node pointers
			size = is64 ? TablePtr::SIZE64 : TablePtr::SIZE32
			# split the data into item_count table pointers
			Pst.split_per(buf, size, item_count).each_with_index do |data, i|
				table = TablePtr.new data, is64
				# for the first value, we expect the start to be equal
				raise 'blah 3' if i == 0 and start_val != 0 and table.start != start_val
				# this shouldn't really happen i'd imagine
				raise "OHNO" if table.start == 0
				load_block_tree table.offset, table.u1, table.start
			end
		end
	end

	# most access to idx objects will use this function
	#
	# corresponds to
	# * _pst_getID
	#
	# @param id [Integer]
	# @return [BlockPtr]
	# @private
	def block_from_id id
		@block_from_id[id & ~1]
	end

	# corresponds to
	# * _pst_build_desc_ptr
	# * record_descriptor
	#
	# @private
	def load_node_btree
		@nodes = []
		@node_offsets = []
		load_node_tree header.node_btree, header.node_btree_count, 0x21

		# first create a lookup cache
		@node_from_id = {}
 		@nodes.each do |node|
			node.pst = self
			warn "there are duplicate desc records with id #{node.node_id}" if @node_from_id[node.node_id]
			@node_from_id[node.node_id] = node
		end

		# now turn the flat list of loaded desc records into a tree

		# well, they have no parent, so they're more like, the toplevel descs.
		@orphans = []
		# now assign each node to the parents child array, putting the orphans in the above
		@nodes.each do |node|
			parent = @node_from_id[node.parent_node_id]
			# note, besides this, its possible to create other circular structures.
			if parent == node
				# this actually happens usually, for the root_item it appears.
				#warn "desc record's parent is itself (#{desc.inspect})"
			# maybe add some more checks in here for circular structures
			elsif parent
				parent.children << node
				next
			end
			@orphans << node
		end

		# maybe change this to some sort of sane-ness check. orphans are expected
#		warn "have #{@orphans.length} orphan desc record(s)." unless @orphans.empty?
	end

	# @return [Boolean]
	# @private
	def is64
		@header.version_2003?
	end

	# load the flat list of desc records recursively
	#
	# corresponds to
	# * _pst_build_desc_ptr
	# * record_descriptor
	#
	# @private
	def load_node_tree offset, linku1, start_val
		@node_offsets << offset
		
		buf = pst_read_block_size offset, NodePtr::BLOCK_SIZE, false
		item_count = buf[is64 ? ITEM_COUNT_OFFSET_64 : ITEM_COUNT_OFFSET].ord
		level = buf[is64 ? LEVEL_INDICATOR_OFFSET_64 : LEVEL_INDICATOR_OFFSET].ord

		# not real desc
		this_node_id = is64 ? Pst.unpack(buf[BACKLINK_OFFSET, 8], "T").first : buf[BACKLINK_OFFSET, 4].unpack("V").first
		raise 'blah 1' unless this_node_id == linku1

		if level == 0
			# leaf pointers
			size = is64 ? NodePtr::SIZE64 : NodePtr::SIZE32
			count_max = is64 ? NodePtr::COUNT_MAX64 : NodePtr::COUNT_MAX32

			raise "have too many active items in index (#{item_count})" if item_count > count_max
			# split the data into item_count desc objects
			Pst.split_per(buf, size, item_count).each_with_index do |data, i|
				node = NodePtr.new data, is64
				# first entry
				raise 'blah 3' if i == 0 and start_val != 0 and node.node_id != start_val
				# this shouldn't really happen i'd imagine
				break if node.node_id == 0
				@nodes << node
			end
		else
			# node pointers
			size = is64 ? TablePtr::SIZE64 : TablePtr::SIZE32
			count_max = is64 ? BlockPtr::COUNT_MAX64 : BlockPtr::COUNT_MAX32

			raise "have too many active items in index (#{item_count})" if item_count > count_max
			# split the data into item_count table pointers
			Pst.split_per(buf, size, item_count).each_with_index do |data, i|
				table = TablePtr.new data, is64
				# for the first value, we expect the start to be equal note that ids -1, so even for the
				# first we expect it to be equal. thats the 0x21 (dec 33) desc record. this means we assert
				# that the first desc record is always 33...
				raise 'blah 3' if i == 0 and start_val != -1 and table.start != start_val
				# this shouldn't really happen i'd imagine
				break if table.start == 0
				load_node_tree table.offset, table.u1, table.start
			end
		end
	end

	# as for idx
	# 
	# corresponds to:
	# * _pst_getDptr
	#
	# @param id [Integer]
	# @return [NodePtr]
	#
	# @private
	def node_from_id id
		@node_from_id[id]
	end

	# corresponds to
	# * pst_load_extended_attributes
	#
	# @private
	def load_xattrib
	end

	# corresponds to:
	# * _pst_read_block_size
	# * _pst_read_block ??
	# * _pst_ff_getIDblock_dec ??
	# * _pst_ff_getIDblock ??
	#
	# @param offset [Integer]
	# @param size [Integer]
	# @param decrypt [Boolean]
	# @return [String]
	# @private
	def pst_read_block_size offset, size, decrypt=true
		io.seek offset
		buf = io.read size
		warn "tried to read #{size} bytes but only got #{buf.length}" if buf.length != size
		encrypted? && decrypt ? CompressibleEncryption.decrypt(buf) : buf
	end

	# @param node_id [Integer]
	# @param list [Array<String>]
	# @private
	def load_node_main_data_to node_id, list
		raise 'node_is must be Integer' unless Integer === node_id
		node = node_from_id node_id
		load_main_block_to node.block_id, list
	end

	# @param node_id [Integer]
	# @param local_node_id [Integer]
	# @param list [Array<String>]
	# @private
	def load_node_sub_data_to node_id, local_node_id, list
		raise 'node_is must be Integer' unless Integer === node_id
		raise 'local_node_id must be Integer' unless Integer === local_node_id
		node = node_from_id node_id
		load_sub_block_to node.sub_block_id, local_node_id, list
	end

	# for debug
	#
	# @param node_id [String]
	# @param list [Array<String>]
	# @private
	def get_local_node_list_to node_id, list
		node = node_from_id node_id
		get_local_node_list_of_sub_block_to node.sub_block_id, list
	end

	# for debug
	#
	# @param sub_block_id [String]
	# @param list [Array<String>]
	# @private
	def get_local_node_list_of_sub_block_to sub_block_id, list
		return if sub_block_id == 0

		sub_block = block_from_id sub_block_id
		p ["WALK",sub_block_id,sub_block]
		raise 'must not be data' if sub_block.data?

		# SLBLOCK or SIBLOCK
		data = sub_block.read

		btype = data[0].ord
		raise 'btype != 2' if btype != 2

		level = data[1].ord
		case level
		when 0 # SLBLOCK
			count = data[2, 2].unpack("v").first
			count.times do |i|
				sl_node_id, sl_block_id, sl_sub_block_id = (
					is64 ? Pst.unpack(data[(is64 ? 8 : 4) + 24 * i, 24], "T3") : data[(is64 ? 8 : 4) + 12 * i, 12].unpack("V3")
				)

				list << (sl_node_id & 0xffffffff)
				
				get_local_node_list_of_sub_block_to sl_sub_block_id, list
			end
		when 1 # SIBLOCK
			count = data[2, 2].unpack("v").first
			count.times do |i|
				si_node_id, si_block_id = (
					is64 ? Pst.unpack(data[(is64 ? 8 : 4) + 16 * i, 16], "T2") : data[(is64 ? 8 : 4) + 8 * i, 8].unpack("V2")
				)

				list << (si_node_id & 0xffffffff)
			end
		else
			raise 'level unk'
		end
	end

	# @param sub_block_id [Integer]
	# @param local_node_id [Integer]
	# @param list [Array<String>]
	# @private
	def load_sub_block_to sub_block_id, local_node_id, list
		raise 'sub_block_id must be Integer' unless Integer === sub_block_id
		return if sub_block_id == 0

		sub_block = block_from_id sub_block_id
		raise 'must not be data' if sub_block.data?

		# SLBLOCK or SIBLOCK
		data = sub_block.read

		btype = data[0].ord
		raise 'btype != 2' if btype != 2

		level = data[1].ord
		case level
		when 0 # SLBLOCK
			count = data[2, 2].unpack("v").first
			count.times do |i|
				sl_node_id, sl_block_id, sl_sub_block_id = (
					is64 ? Pst.unpack(data[(is64 ? 8 : 4) + 24 * i, 24], "T3") : data[(is64 ? 8 : 4) + 12 * i, 12].unpack("V3")
				)

				sl_node_id &= 0xffffffff
				
				if sl_node_id == local_node_id
					load_main_block_to sl_block_id, list
				end

				load_sub_block_to sl_sub_block_id, local_node_id, list
			end
		when 1 # SIBLOCK
			count = data[2, 2].unpack("v").first
			count.times do |i|
				si_node_id, si_block_id = (
					is64 ? Pst.unpack(data[(is64 ? 8 : 4) + 16 * i, 16], "T2") : data[(is64 ? 8 : 4) + 8 * i, 8].unpack("V2")
				)

				si_node_id &= 0xffffffff

				if si_node_id == local_node_id
					si_block = block_from_id si_block_id
					raise 'must be data' unless si_block.data?
					list << si_block.read.force_encoding("BINARY")
				end
			end
		else
			raise 'level unk'
		end
	end

	# @param block_id [Integer]
	# @param list [Array<String>]
	# @private
	def load_main_block_to block_id, list
		return if block_id == 0

		block = block_from_id block_id

		if block.data?
			# this is real data we want
			list << block.read.force_encoding("BINARY")
			return
		end

		# XBLOCK or XXBLOCK
		data = block.read

		btype = data[0].ord
		raise 'btype must be 1' if btype != 1

		level = data[1].ord
		case level
		when 1, 2
			count, num_bytes = data[2, 6].unpack("vV")

			items = (
				is64 ? Pst.unpack(data[8, 8 * count], "T#{count}") : data[8, 4 * count].unpack("V#{count}")
			)
			items.each { |block_id|
				load_main_block_to block_id, list
			}
		else
			raise 'level unk'
		end
	end

	#
	# id2 
	# ----------------------------------------------------------------------------
	#

	#
	# main block parsing code. gets raw properties
	# ----------------------------------------------------------------------------
	#

	# the job of this class, is to take a desc record, and be able to enumerate through the
	# mapi properties of the associated thing.
	#
	# corresponds to
	# * _pst_parse_block
	# * _pst_process (in some ways. although perhaps thats more the Item::Properties#add_property)
	#
	# @private
	class BlockParser
		include Mapi::Types::Constants

		# @private
		TYPES = {
			0xbc => 1,
			0x7c => 2,
			# type 3 is removed. an artifact of not handling the indirect blocks properly in libpst.
		}

		# @private
		PR_SUBJECT = PropertySet::TAGS.find { |num, (name, type)| name == 'PR_SUBJECT' }.first.hex
		# @private
		PR_BODY_HTML = PropertySet::TAGS.find { |num, (name, type)| name == 'PR_BODY_HTML' }.first.hex

		# this stuff could maybe be moved to Ole::Types? or leverage it somehow?
		# whether or not a type is immeidate is more a property of the pst encoding though i expect.
		# what i probably can add is a generic concept of whether a type is of variadic length or not.

		# these lists are very incomplete. think they are largely copied from libpst

		# @private
		IMMEDIATE_TYPES = [
			PT_SHORT, PT_LONG, PT_BOOLEAN
		]

		# @private
		INDIRECT_TYPES = [
			PT_DOUBLE, PT_OBJECT,
			0x0014, # whats this? probably something like PT_LONGLONG, given the correspondence with the
							# ole variant types. (= VT_I8)
			PT_STRING8, PT_UNICODE, # unicode isn't in libpst, but added here for outlook 2003 down the track
			PT_SYSTIME,
			0x0048, # another unknown
			0x0102, # this is PT_BINARY vs PT_CLSID
			#0x1003, # these are vector types, but they're commented out for now because i'd expect that
			#0x1014, # there's extra decoding needed that i'm not doing. (probably just need a simple
			#        # PT_* => unpack string mapping for the immediate types, and just do unpack('V*') etc
			#0x101e,
			#0x1102
		]

		# the attachment and recipient arrays appear to be always stored with these fixed
		# id2 values. seems strange. are there other extra streams? can find out by making higher
		# level IO wrapper, which has the id2 value, and doing the diff of available id2 values versus
		# used id2 values in properties of an item.

		# @private
		ID2_ATTACHMENTS = 0x671

		# @private
		ID2_RECIPIENTS = 0x692

		# Targeting main data, not sub
		USE_MAIN_DATA = -1

		# @return [NodePtr]
		# @private
		attr_reader :node

		# @return [Hash<Integer, String>] HID to data block
		# @private
		attr_reader :data_chunks

		# @param node [NodePtr]
		# @param local_node_id [Integer]
		def initialize node, local_node_id = USE_MAIN_DATA
			#raise FormatError, "unable to get associated index record for #{node.inspect}" unless node.block
			@node = node
			@data_chunks = {}

			data_array = (local_node_id == USE_MAIN_DATA) ? node.read_main_array : (node.read_sub_array local_node_id)

			data_array.each_with_index { |data, index|
				# see https://docs.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/a3fa280c-eba3-434f-86e4-b95141b3c7b1
				if index == 0
					load_root_header data
				else
					load_page_header data, index
				end
			}

			# now, we may have multiple different blocks
		end

		# Parse HNPAGEHDR / HNBITMAPHDR
		#
		# @see https://docs.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/9c34ecf8-36bc-45a1-a2df-ee35c6dc840a
		# 
		# @param data [String]
		# @param page_index [Integer]
		# @private
		def load_page_header data, page_index
			page_map = data.unpack('v').first

			# read HNPAGEMAP
			offsets_count = data[page_map, 2].unpack("v").first + 1
			offset_tables = data[page_map + 4, 2 * offsets_count].unpack("v#{offsets_count}")

			offset_tables.each_cons(2).to_a.each_with_index do |(from, to), index|
				# conver to HID
				@data_chunks[0x20 * (1 + index) + 65536 * page_index] = data[from, to - from]
			end
		end

		# Parse HNHDR
		#
		# @see https://docs.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/8e4ae05c-3c24-4103-b7e5-ffef6f244834
		# @private
		def load_root_header data
			page_map, sig, @heap_type, @offset1 = data.unpack 'vCCVV'
			raise FormatError, 'invalid signature 0x%02x' % sig unless sig == 0xec
			raise FormatError, 'unknown block type signature 0x%02x' % @heap_type unless TYPES[@heap_type]
			@type = TYPES[@heap_type]

			# read HNPAGEMAP
			offsets_count = data[page_map, 2].unpack("v").first + 1
			offset_tables = data[page_map + 4, 2 * offsets_count].unpack("v#{offsets_count}")

			offset_tables.each_cons(2).to_a.each_with_index do |(from, to), index|
				# conver to HID
				@data_chunks[0x20 * (1 + index)] = data[from, to - from]
			end
		end

		# based on the value of offset, return either some data from buf, or some data from the
		# id2 chain id2, where offset is some key into a lookup table that is stored as the id2
		# chain. i think i may need to create a BlockParser class that wraps up all this mess.
		#
		# corresponds to:
		# * _pst_getBlockOffsetPointer
		# * _pst_getBlockOffset
		# 
		# @param offset [Integer]
		# @return [String]
		# @private
		def get_data_indirect offset
			raise "offset must be Integer" unless Integer === offset

			return get_data_indirect_io(offset).read
		end

		# Resolve data pointed by HNID
		#
		# @see https://docs.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/7ac490ce-31af-4a75-97df-eb9d07a003fd
		# @param offset [Integer]
		# @return [StringIO]
		# @private
		def get_data_indirect_io offset
			raise "offset must be Integer" unless Integer === offset

			if offset == 0
				nil
			elsif (offset & 0x1f) != 0
				# this is NID (node)
				data_array = node.read_sub_array(offset)
				raise "local node id #{offset} points multi page count #{data_array.count}, use get_data_array() instead" if data_array.count >= 2
				if data_array.empty?
					StringIO.new ""
				else
					StringIO.new data_array.first
				end
			else
				# this is HID (heap)
				StringIO.new data_chunks[offset]
			end
		end

		# @param offset [Integer]
		# @return [Array<String>]
		# @private
		def get_data_array offset
			raise "offset must be Integer" unless Integer === offset

			if offset == 0
				nil
			elsif (offset & 0x1f) != 0
				# this is NID (node)
				node.read_sub_array(offset)
			else
				# this is HID (heap)
				[data_chunks[offset]]
			end
		end

		def handle_indirect_values key, type, value
			case type
			when PT_BOOLEAN
				value = value != 0
			when *IMMEDIATE_TYPES # not including PT_BOOLEAN which we just did above
				# no processing current applied (needed?).
			when *INDIRECT_TYPES
				# the value is a pointer
				if String === value # ie, value size > 4 above
					value = StringIO.new value
				else
					value = get_data_array(value)
					if value
						value = StringIO.new value.join("")
					end
				end
				# keep strings as immediate values for now, for compatability with how i set up
				# Msg::Properties::ENCODINGS
				if value
					if type == PT_STRING8
						value = node.pst.helper.convert_ansi_str value.read
					elsif type == PT_UNICODE
						value = Ole::Types::FROM_UTF16.iconv value.read
					end
				end
				# special subject handling
				if key == PR_BODY_HTML and value
					# to keep the msg code happy, which thinks body_html will be an io
					# although, in 2003 version, they are 0102 already
					value = StringIO.new value unless value.respond_to?(:read)
				end
				if key == PR_SUBJECT and String === value and value.length >= 2
					if value[0].ord == 1
						# This 2 chars header tell us how to omit subject prefix like `Yes: `, `Re: `, etc.
						# We need not to omit them.
						value = value[2..-1]
					end
=begin
					index = value =~ /^[A-Z]*:/ ? $~[0].length - 1 : nil
					unless ignore == 1 and offset == index
						warn 'something wrong with subject hack' 
						$x = [ignore, offset, value]
						require 'irb'
						IRB.start
						exit
					end
=end
=begin
new idea:

making sense of the \001\00[156] i've seen prefixing subject. i think its to do with the placement
of the ':', or the ' '. And perhaps an optimization to do with thread topic, and ignoring the prefixes
added by mailers. thread topic is equal to subject with all that crap removed.

can test by creating some mails with bizarre subjects.

subject="\001\005RE: blah blah"
subject="\001\001blah blah"
subject="\001\032Out of Office AutoReply: blah blah"
subject="\001\020Undeliverable: blah blah"

looks like it

=end

					# now what i think, is that perhaps, value[offset..-1] ...
					# or something like that should be stored as a special tag. ie, do a double yield
					# for this case. probably PR_CONVERSATION_TOPIC, in which case i'd write instead:
					# yield [PR_SUBJECT, ref_type, value]
					# yield [PR_CONVERSATION_TOPIC, ref_type, value[offset..-1]
					# next # to skip the yield.
				end

				# special handling for embedded objects
				# used for attach_data for attached messages. in which case attach_method should == 5,
				# for embedded object.
				if type == PT_OBJECT and value
					value = value.read if value.respond_to?(:read)
					id2, unknown = value.unpack 'V2'
					io = get_data_indirect_io id2

					# hacky
					#desc2 = OpenStruct.new(:node => io, :pst => node.pst, :sub_block => node.sub_block, :children => [])
					# put nil instead of desc.list_index, otherwise the attachment is attached to itself ad infinitum.
					# should try and fix that FIXME
					# this shouldn't be done always. for an attached message, yes, but for an attached
					# meta file, for example, it shouldn't. difference between embedded_ole vs embedded_msg
					# really.
					# note that in the case where its a embedded ole, you actually get a regular serialized ole
					# object, so i need to create an ole storage object on a rangesioidxchain!
					# eg:
=begin
att.props.display_name # => "Picture (Metafile)"
io = att.props.attach_data
io.read(32).unpack('H*') # => ["d0cf11e0a1b11ae100000.... note the docfile signature.
# plug some missing rangesio holes:
def io.rewind; seek 0; end
def io.flush; raise IOError; end
ole = Ole::Storage.open io
puts ole.root.to_tree

- #<Dirent:"Root Entry">
  |- #<Dirent:"\001Ole" size=20 data="\001\000\000\002\000...">
  |- #<Dirent:"CONTENTS" size=65696 data="\327\315\306\232\000...">
  \- #<Dirent:"\003MailStream" size=12 data="\001\000\000\000[...">
=end
					# until properly fixed, i have disabled this code here, so this will break
					# nested messages temporarily.
					#value = Item.new desc2, RawPropertyStore.new(desc2).to_a
					#desc2.list_index = nil
					value = io
				end
			# this is PT_MV_STRING8, i guess.
			# should probably have the 0x1000 flag, and do the or-ring.
			# example of 0x1102 is PR_OUTLOOK_2003_ENTRYIDS. less sure about that one.
			when 0x101e, 0x1102
				# example data:
				# 0x802b "\003\000\000\000\020\000\000\000\030\000\000\000#\000\000\000BusinessCompetitionFavorites"
				# this 0x802b would be an extended attribute for categories / keywords.
				value = get_data_indirect_io(value).read unless String === value
				num = value.unpack('V')[0]
				offsets = value[4, 4 * num].unpack("V#{num}")
				value = (offsets + [value.length]).to_enum(:each_cons, 2).map { |from, to| value[from...to] }
				value.map! { |str| StringIO.new str } if type == 0x1102
			when 0x101f
				value = get_data_indirect_io(value).read unless String === value
				num = value.unpack('V')[0]
				offsets = value[4, 4 * num].unpack("V#{num}")
				value = (offsets + [value.length]).to_enum(:each_cons, 2).map { |from, to| value[from...to] }
				value.map! { |str| Ole::Types::FROM_UTF16.iconv str }
			when 0x1003 # uint32 array
				value = get_data_indirect_io(value).read unless String === value
				# there is no count field
				value = value.unpack("V#{(value.length / 4)}")
			else
				name = Mapi::Types::DATA[type].first rescue nil
				warn '0x%04x %p' % [key, get_data_indirect_io(value).read]
				raise NotImplementedError, 'unsupported mapi property type - 0x%04x (%p)' % [type, name]
			end
			[key, type, value]
		end
	end

=begin
* recipients:

	affects: ["0x200764", "0x2011c4", "0x201b24", "0x201b44", "0x201ba4", "0x201c24", "0x201cc4", "0x202504"]

after adding the rawpropertystoretable fix, all except the second parse properly, and satisfy:

  item.props.display_to == item.recipients.map { |r| r.props.display_name if r.props.recipient_type == 1 }.compact * '; '

only the second still has a problem

#[#<struct Pst::Desc desc_id=0x2011c4, idx_id=0x397c, idx2_id=0x398a, parent_desc_id=0x8082>]

think this is related to a multi block #data3. ie, when you use @x * rec_size, and it
goes > 8190, or there abouts, then it stuffs up. probably there is header gunk, or something,
similar to when #data is multi block.

same problem affects the attachment table in test4. 

fixed that issue. round data3 ranges to rec_size. 

fix other issue with attached objects.

all recipients and attachments in test2 are fine.

only remaining issue is test4 recipients of 200044. strange.

=end

	# RawPropertyStore is used to iterate through the properties of an item, or the auxiliary
	# data for an attachment. its just a parser for the way the properties are serialized, when the
	# properties don't have to conform to a column structure.
	#
	# structure of this chunk of data is often
	#   header, property keys, data values, and then indexes.
	# the property keys has value in it. value can be the actual value if its a short type,
	# otherwise you lookup the value in the indicies, where you get the offsets to use in the
	# main data body. due to the indirect thing though, any of these parts could actually come
	# from a separate stream.
	#
	# @private
	class RawPropertyStore < BlockParser
		include Enumerable

		# @return [Integer] number of property tuples
		attr_reader :length

		# Will read Property Context (PC)
		#
		# @see https://docs.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/294c83c6-ff92-42f5-b6b6-876c29fa9737
		# @param desc [NodePtr]
		# @param local_node_id [Integer]
		def initialize node, local_node_id = USE_MAIN_DATA
			super
			bTypePC = 0xbc
			raise FormatError, "expected type 188 - got #{@heap_type}" unless @heap_type == bTypePC

			# the way that offset works, data1 may be a subset of buf, or something from id2. if its from buf,
			# it will be offset based on index_offset and offset. so it could be some random chunk of data anywhere
			# in the thing.
			header_data = get_data_indirect @offset1
			raise FormatError if header_data.length < 8
			signature, offset2 = header_data.unpack 'V2'
			raise FormatError, 'invalid Property Context signature 0x%08x' % @type if signature != 0x000602b5
			# this is actually a big chunk of tag tuples.
			@index_data = get_data_indirect offset2
			@length = @index_data.length / 8
		end

		# iterate through the property tuples
		#
		# @yield [key, type, value]
		# @yieldparam key [Integer]
		# @yieldparam type [Integer]
		# @yieldparam value [Object]
		def each
			length.times do |i|
				key, type, value = handle_indirect_values(*@index_data[8 * i, 8].unpack('vvV'))
				yield key, type, value
			end
		end
	end

	# RawPropertyStoreTable is kind of like a database table.
	# it has a fixed set of columns.
	# #[] is kind of like getting a row from the table.
	# those rows are currently encapsulated by Row, which has #each like
	# RawPropertyStore.
	# only used for the recipients array, and the attachments array. completely lazy, doesn't
	# load any of the properties upon creation. 
	#
	# @private
	class RawPropertyStoreTable < BlockParser
		# TCOLDESC
		# @private
		class Column < Struct.new(:ref_type, :type, :ind2_off, :size, :slot)
			def initialize data
				super(*data.unpack('v3CC'))
			end

			def nice_type_name
				Mapi::Types::DATA[ref_type].first[/_(.*)/, 1].downcase rescue '0x%04x' % ref_type
			end

			def nice_prop_name
				Mapi::PropertyStore::TAGS['%04x' % type].first[/_(.*)/, 1].downcase rescue '0x%04x' % type
			end

			def inspect
				"#<#{self.class} name=#{nice_prop_name.inspect}, type=#{nice_type_name.inspect}>"
			end
		end

		include Enumerable

		# @return [Integer] record count
		attr_reader :length
		# @return [String] Array of TCOLDESC
		attr_reader :index_data
		# @return [String] 2.3.2 BTree-on-Heap (BTH)
		attr_reader :data2
		# @return [Array<String>] 2.3.4.4 Row Matrix
		attr_reader :rows_pages
		# @return [Integer] TCI_bm
		attr_reader :rec_size
		# @return [Integer] 
		attr_reader :rows_per_page

		# @param node [NodePtr]
		# @param local_node_id [Integer]
		def initialize node, local_node_id
			super
			bTypeTC = 0x7c
			raise FormatError, "expected type 124 - got #{@heap_type}" unless @heap_type == bTypeTC

			header_data = get_data_indirect @offset1
			# seven_c_blk
			# often: u1 == u2 and u3 == u2 + 2, then rec_size == u3 + 4. wtf
			# TCINFO
			seven_c, @num_list, u1, u2, u3, @rec_size, b_five_offset,
				rows_offset, u7, u8 = header_data[0, 22].unpack('CCv4V2v2')
			@index_data = header_data[22..-1]

			raise FormatError if @num_list != schema.length or seven_c != 0x7c
			# another check
			min_size = schema.inject(0) { |total, col| total + col.size }
			# seem to have at max, 8 padding bytes on the end of the record. not sure if it means
			# anything. maybe its just space that hasn't been reclaimed due to columns being
			# removed or something. probably should just check lower bound. 
			range = (min_size..min_size + 8)
			warn "rec_size seems wrong (#{range} !=== #{rec_size})" unless range === rec_size

			header_data2 = get_data_indirect b_five_offset
			raise FormatError if header_data2.length < 8
			signature, offset2 = header_data2.unpack 'V2'
			# ??? seems a bit iffy
			# there's probably more to the differences than this, and the data2 difference below
			expect = node.pst.header.version_2003? ? 0x000404b5 : 0x000204b5
			raise FormatError, 'unhandled block signature 0x%08x' % signature if signature != expect

			# this holds all the row data
			# handle multiple block issue.
			if rows_offset != 0
				#if RangesIOIdxChain === @rows_io
				#	@data3_idxs = 
				#	# modify ranges
				#	ranges = @rows_io.ranges.map { |offset, size| [offset, size / @rec_size * @rec_size] }
				#	@rows_io.instance_variable_set :@ranges, ranges
				#end
				@rows_pages = get_data_array(rows_offset)
			else
				# table rows are empty, no data to be read
				@rows_pages = [""]
			end

			# there must be something to the data in data2. i think data2 is the array of objects essentially.
			# currently its only used to imply a length
			# actually, at size 6, its just some auxiliary data. i'm thinking either Vv/vV, for 97, and something
			# wider for 03. the second value is just the index (0...length), and the first value is
			# some kind of offset i expect. actually, they were all id2 values, in another case.
			# so maybe they're get_data_indirect values too?
			# actually, it turned out they were identical to the PR_ATTACHMENT_ID2 values...
			# id2_values = ie, data2.unpack('v*').to_enum(:each_slice, 3).transpose[0]
			# table[i].assoc(PR_ATTACHMENT_ID2).last == id2_values[i], for all i. 
			@data2 = get_data_indirect(offset2) rescue nil
			#if data2
			#	@length = (data2.length / 6.0).ceil
			#else
			# the above / 6, may have been ok for 97 files, but the new 0x0004 style block must have
			# different size records... just use this instead:
				# hmmm, actually, we can still figure it out:
			@rows_per_page = @rows_pages.first.length / @rec_size

			@length = @rows_pages.map { |data| data.length / @rec_size }.sum

			#end

			# lets try and at least use data2 for a warning for now
			#if data2
			#	data2_rec_size = node.pst.header.version_2003? ? 8 : 6
			#	warn 'somthing seems wrong with data3' unless @length == (data2.length / data2_rec_size)
			#end
		end

		# for debug
		#
		# @return [Array<Column>]
		# @private
		def schema
			@schema ||= Pst.split_per(index_data, 8, -1).map { |data| Column.new data }
		end

		# return grid row
		#
		# @param idx [Integer]
		# @return [Row]
		def [] idx
			# handle funky rounding
			Row.new self, idx
		end

		# @yield [row]
		# @yieldparam row [Row]
		def each
			length.times { |i| yield self[i] }
		end

		# get record data
		#
		# @param record_index [Integer]
		# @return [String]
		# @private
		def get_record record_index
			page_index = record_index / @rows_per_page
			heap_index = record_index % @rows_per_page
			(@rows_pages[page_index])[@rec_size * heap_index, @rec_size]
		end

		class Row
			include Enumerable

			# @param array_parser [RawPropertyStoreTable]
			# @param index [Integer]
			def initialize array_parser, index
				@array_parser = array_parser
				@index = index
				@data = @array_parser.get_record(index)
			end

			# iterate through the property tuples
			#
			# @yield [key, type, value]
			# @yieldparam key [Integer]
			# @yieldparam type [Integer]
			# @yieldparam value [Object]
			def each
				(@array_parser.index_data.length / 8).times do |i|
					ref_type, type, ind2_off, size, slot = @array_parser.index_data[8 * i, 8].unpack 'v3CC'
					# check this rescue too
					value = @data[ind2_off, size]
#					if INDIRECT_TYPES.include? ref_type
					if size <= 4
						value = value.unpack('V')[0]
					end
					#p ['0x%04x' % ref_type, '0x%04x' % type, (Msg::Properties::MAPITAGS['%04x' % type].first[/^.._(.*)/, 1].downcase rescue nil),
					#		value_orig, value, (get_data_indirect(value_orig.unpack('V')[0]) rescue nil), size, ind2_off, slot]
					key, type, value = @array_parser.handle_indirect_values type, ref_type, value
					yield key, type, value
				end
			end
		end
	end

	# @private
	class AttachmentTable < BlockParser
		# a "fake" MAPI property name for this constant. if you get a mapi property with
		# this value, it is the id2 value to use to get attachment data.
		#
		# @private
		PR_ATTACHMENT_ID2 = 0x67f2

		# @return [NodePtr]
		# @private
		attr_reader :node
		# @return [RawPropertyStoreTable]
		# @private
		attr_reader :table

		# @param node [NodePtr]
		def initialize node
			@node = node
			# no super, we only actually want BlockParser2#idx2
			#@table = nil
			#return unless node.sub_block
			#return unless block = sub_block[ID2_ATTACHMENTS]
			## FIXME make a fake desc.
			#@fake_node = OpenStruct.new :block => block, :pst => node.pst, :sub_block => node.sub_block
			if @node.has_sub ID2_ATTACHMENTS
				@table = RawPropertyStoreTable.new @node, ID2_ATTACHMENTS
			else
				@table = []
			end
		end

		# @return [Array<Array<Array(Integer, Integer, Object)>>]
		def to_a
			return [] if !table
			table.map do |attachment|
				attachment = attachment.to_a
				# potentially merge with yet more properties
				# this still seems pretty broken - especially the property overlap
				if attachment_id2 = attachment.assoc(PR_ATTACHMENT_ID2)
					# verify existence of this record
					if @node.has_sub attachment_id2.last
						RawPropertyStore.new(@node, attachment_id2.last).each do |a, b, c|
							record = attachment.assoc a
							attachment << record = [] unless record
							record.replace [a, b, c]
						end
					else
						warn "attachment record is missing"
					end
				end
				attachment
			end
		end
	end

	# there is no equivalent to this in libpst. ID2_RECIPIENTS was just guessed given the above
	# AttachmentTable.
	#
	# @private
	class RecipientTable < BlockParser
		# @return [NodePtr]
		# @private
		attr_reader :node
		# @return [RawPropertyStoreTable]
		# @private
		attr_reader :table

		# @param node [NodePtr]
		def initialize node
			@node = node
			# no super, we only actually want BlockParser2#idx2
			#@table = nil
			#return unless node.sub_block
			#return unless block = sub_block[ID2_RECIPIENTS]
			## FIXME make a fake desc.
			#fake_node = OpenStruct.new :block => block, :pst => node.pst, :sub_block => node.sub_block
			if @node.has_sub ID2_RECIPIENTS
				@table = RawPropertyStoreTable.new @node, ID2_RECIPIENTS
			else
				@table = []
			end

		end

		# @return [Array<Array<Array(Integer, Integer, Object)>>]
		def to_a
			return [] if !table
			table.map { |x| x.to_a }
		end
	end

	#
	# higher level item code. wraps up the raw properties above, and gives nice
	# objects to work with. handles item relationships too.
	# ----------------------------------------------------------------------------
	#

	# @param property_list [Array<Array(Integer, Integer, Object)>]
	# @return [PropertySet]
	# @private
	def self.make_property_set property_list
		hash = property_list.inject({}) do |hash, (key, type, value)|
			hash.update PropertySet::Key.new(key) => value
		end
		PropertySet.new hash
	end

	class Attachment < Mapi::Attachment
		def initialize list
			super Pst.make_property_set(list)

			@embedded_msg = props.attach_data if Item === props.attach_data
		end
	end

	class Recipient < Mapi::Recipient
		def initialize list
			super Pst.make_property_set(list)
		end
	end

	class Item < Mapi::Message
		# @private
		class EntryID < Struct.new(:u1, :entry_id, :id)
			UNPACK_STR = 'VA16V'

			def initialize data
				data = data.unpack(UNPACK_STR) if String === data
				super(*data)
			end
		end

		include RecursivelyEnumerable

		# Obtain item type
		# 
		# - `:folder`
		# - `:message`
		# - `:wastebasket`
		#
		# @return [Symbol]
		attr_accessor :type

		# @return [Item]
		attr_accessor :parent

		# @param node [NodePtr]
		# @param list [Array]
		# @param type [Object, nil]
		def initialize node, list, type=nil
			@node = node
			super Pst.make_property_set(list)

			# this is kind of weird, but the ids of the special folders are stored in a hash
			# when the root item is loaded
			if ipm_wastebasket_entryid
				node.pst.special_folder_ids[ipm_wastebasket_entryid] = :wastebasket
			end

			if finder_entryid
				node.pst.special_folder_ids[finder_entryid] = :finder
			end

			# and then here, those are used, along with a crappy heuristic to determine if we are an
			# item
=begin
i think the low bits of the desc_id can give some info on the type.

it seems that 0x4 is for regular messages (and maybe contacts etc)
0x2 is for folders, and 0x8 is for special things like rules etc, that aren't visible.
=end
			unless type
				type = props.valid_folder_mask || ipm_subtree_entryid || props.content_count || props.subfolders ? :folder : :message
				if type == :folder
					type = node.pst.special_folder_ids[node.node_id] || type
				end
			end

			@type = type
		end

		# @yield [item]
		# @yieldparam item [Item]
		# @return [void]
		def each_child
			id = ipm_subtree_entryid
			if id
				root = @node.pst.node_from_id id
				raise "couldn't find root" unless root
				raise 'both kinds of children' unless @node.children.empty?
				children = root.children
				# lets look up the other ids we have.
				# typically the wastebasket one "deleted items" is in the children already, but
				# the search folder isn't.
				extras = [ipm_wastebasket_entryid, finder_entryid].compact.map do |id|
					root = @node.pst.node_from_id id
					warn "couldn't find root for id #{id}" unless root
					root
				end.compact
				# i do this instead of union, so as not to mess with the order of the
				# existing children.
				children += (extras - children)
				children
			else
				@node.children
			end.each do |node|
				item = @node.pst.pst_parse_item(node)
				item.parent = self
				yield item
			end
		end

		# @return [String]
		def path
			parents, item = [], self
			parents.unshift item while item = item.parent
			# remove root
			parents.shift
			parents.map { |item| item.props.display_name or raise 'unable to construct path' } * '/'
		end

		# Enumerate direct children
		#
		# @return [Array<Item>]
		def children
			to_enum(:each_child).to_a
		end

		# these are still around because they do different stuff

		# Top of Personal Folder Record
		#
		# @private
		def ipm_subtree_entryid
			@ipm_subtree_entryid ||= EntryID.new(props.ipm_subtree_entryid.read).id rescue nil
		end

		# Deleted Items Folder Record
		#
		# @private
		def ipm_wastebasket_entryid
			@ipm_wastebasket_entryid ||= EntryID.new(props.ipm_wastebasket_entryid.read).id rescue nil
		end

		# Search Root Record
		#
		# @private
		def finder_entryid
			@finder_entryid ||= EntryID.new(props.finder_entryid.read).id rescue nil
		end

		# all these have been replaced with the method_missing below
=begin
		# States which folders are valid for this message store 
		#def valid_folder_mask
		#	props[0x35df]
		#end

		# Number of emails stored in a folder
		def content_count
			props[0x3602] 
		end

		# Has children
		def subfolders
			props[0x360a]
		end
=end

		# i think i will change these, so they can inherit the lazyness from RawPropertyStoreTable.
		# so if you want the last attachment, you can get it without creating the others perhaps.
		# it just has to handle the no table at all case a bit more gracefully.

		# @return [Array<Attachment>]
		def attachments
			@attachments ||= AttachmentTable.new(@node).to_a.map { |list| Attachment.new list }
		end

		# @return [Array<Recipient>]
		def recipients
			#[]
			@recipients ||= RecipientTable.new(@node).to_a.map { |list| Recipient.new list }
		end

		# Iterate children (except on this instance) recursively stored in this MessageStore.
		#
		# @yield [item]
		# @yieldparam item [Item]
		# @return [void]
		def each_recursive(&block)
			#p :self => self
			children.each do |child|
				#p :child => child
				block[child]
				child.each_recursive(&block)
			end
		end

		def inspect
			attrs = %w[display_name subject sender_name subfolders]
#			attrs = %w[display_name valid_folder_mask ipm_wastebasket_entryid finder_entryid content_count subfolders]
			str = attrs.map { |a| b = props.send a; " #{a}=#{b.inspect}" if b }.compact * ','

			type_s = type == :message ? 'Message' : type == :folder ? 'Folder' : type.to_s.capitalize + 'Folder'
			str2 = 'node_id=0x%x' % @node.node_id

			!str.empty? ? "#<Pst::#{type_s} #{str2}#{str}>" : "#<Pst::#{type_s} #{str2} props=#{props.inspect}>" #\n" + props.transport_message_headers + ">"
		end
	end

	# corresponds to
	# * _pst_parse_item
	#
	# @param desc [NodePtr]
	# @return [Item]
	# @private
	def pst_parse_item node
		Item.new node, RawPropertyStore.new(node).to_a
	end

	#
	# other random code
	# ----------------------------------------------------------------------------
	#

	# @private
	def dump_debug_info
		puts "* pst header"
		p header

=begin
Looking at the output of this, for blank-o1997.pst, i see this part:
...
- (26624,516) desc block data (overlap of 4 bytes)
- (27136,516) desc block data (gap of 508 bytes)
- (28160,516) desc block data (gap of 2620 bytes)
...

which confirms my belief that the block size for idx and desc is more likely 512
=end
		if 0 + 0 == 0
			puts '* file range usage'
			file_ranges =
				# these 3 things, should account for most of the data in the file.
				[[0, Header::SIZE, 'pst file header']] +
				@block_offsets.map { |offset| [offset, BlockPtr::BLOCK_SIZE, 'block data'] } +
				@node_offsets.map { |offset| [offset, NodePtr::BLOCK_SIZE, 'node data'] } +
				@blocks.map { |idx| [idx.offset, idx.size, 'idx id=0x%x (%s)' % [idx.id, idx.type]] }
			(file_ranges.sort_by { |idx| idx.first } + [nil]).to_enum(:each_cons, 2).each do |(offset, size, name), next_record|
				# i think there is a padding of the size out to 64 bytes
				# which is equivalent to padding out the final offset, because i think the offset is 
				# similarly oriented
				pad_amount = 64
				warn 'i am wrong about the offset padding' if offset % pad_amount != 0
				# so, assuming i'm not wrong about that, then we can calculate how much padding is needed.
				pad = pad_amount - (size % pad_amount)
				pad = 0 if pad == pad_amount
				gap = next_record ? next_record.first - (offset + size + pad) : 0
				extra = case gap <=> 0
					when -1; ["overlap of #{gap.abs} bytes)"]
					when  0; []
					when +1; ["gap of #{gap} bytes"]
				end
				# how about we check that padding
				@io.pos = offset + size
				pad_bytes = @io.read(pad)
				extra += ["padding not all zero"] unless pad_bytes == 0.chr * pad
				puts "- #{offset}:#{size}+#{pad} #{name.inspect}" + (extra.empty? ? '' : ' [' + extra * ', ' + ']')
			end
		end

		# i think the idea of the idx, and indeed the idx2, is just to be able to
		# refer to data indirectly, which means it can get moved around, and you just update
		# the idx table. it is simply a list of file offsets and sizes.
		# not sure i get how id2 plays into it though....
		# the sizes seem to be all even. is that a co-incidence? and the ids are all even. that
		# seems to be related to something else (see the (id & 2) == 1 stuff)
		puts '* idx entries'
		@blocks.each { |idx| puts "- #{idx.inspect}" }

		# if you look at the desc tree, you notice a few things:
		# 1. there is a desc that seems to be the parent of all the folders, messages etc.
		#    it is the one whose parent is itself.
		#    one of its children is referenced as the subtree_entryid of the first desc item,
		#    the root.
		# 2. typically only 2 types of desc records have idx2_id != 0. messages themselves,
		#    and the desc with id = 0x61 - the xattrib container. everything else uses the
		#    regular ids to find its data. i think it should be reframed as small blocks and
		#    big blocks, but i'll look into it more.
		#
		# idx_id and idx2_id are for getting to the data. desc_id and parent_desc_id just define
		# the parent <-> child relationship, and the desc_ids are how the items are referred to in
		# entryids.
		# note that these aren't unique! eg for 0, 4 etc. i expect these'd never change, as the ids
		# are stored in entryids. whereas the idx and idx2 could be a bit more volatile.
		puts '* node tree'
		# make a dummy root hold everything just for convenience
		root = NodePtr.new ''
		def root.inspect; "#<Pst::Root>"; end
		root.children.replace @orphans
		# this still loads the whole thing as a string for gsub. should use directo output io
		# version.
		puts root.to_tree.gsub(/, (parent_node_id|idx2_id)=0x0(?!\d)/, '')

		# this is fairly easy to understand, its just an attempt to display the pst items in a tree form
		# which resembles what you'd see in outlook.
		puts '* item tree'
		# now streams directly
		root_item.to_tree STDOUT
	end

	# @return [NodePtr]
	# @private
	def root_desc
		@nodes.first
	end

	# @return [Item]
	# @private
	def root_item
		item = pst_parse_item root_desc
		item.type = :root
		item
	end

	# Obtain a root item
	#
	# @return [Item]
	def root
		root_item
	end

	# depth first search of all items
	include Enumerable

	# Iterate all kind of items recursively stored in this MessageStore.
	#
	# @yield [message]
	# @yieldparam message [Item]
	# @return [void]
	def each(&block)
		root = self.root
		block[root]
		root.each_recursive(&block)
	end

	# Get this MessageStore's display name.
	#
	# @return [String]
	def name
		@name ||= root_item.props.display_name
	end
	
	def inspect
		"#<Pst name=#{name.inspect} io=#{io.inspect}>"
	end
end
end

