module Mapi
	# This is a helper class for {Pst} and {Msg}.
	# Used to decode some data that depend on its user context.
	# For example like ANSI encoding.
	class Helper
		# @return [String, nil]
		attr_reader :ansi_encoding
		# @return [Boolean]
		attr_reader :to_unicode

		# @param ansi_encoding [String]
		# @param to_unicode [Boolean]
		def initialize ansi_encoding=nil, to_unicode=false
			@ansi_encoding = ansi_encoding || "BINARY"
			@to_unicode = to_unicode
		end

		# Convert from `ASCII_8BIT` string into UTF_8 string or arbitrary object.
		#
		# Use cases:
		# 
		# - Decode PT_STRING8 in {Pst}
		# - Decode `0x001e` in {Msg}
		# - Decode body (rtf, text) in {PropertySet}
		#
		# @param str [String]
		# @return [Object]
		def convert_ansi_str str
			if @ansi_encoding
				if @to_unicode
					# assume we can convert this text to UTF-8
					begin
						str.force_encoding(@ansi_encoding).encode("UTF-8")
					rescue Encoding::UndefinedConversionError => ex
						# some text are already UTF-8 due to unknown reason
						str.force_encoding("UTF-8").encode("UTF-8")
					end
				else
					str.force_encoding(@ansi_encoding)
				end
			else
				str
			end
		end
	end
end