#! /usr/bin/ruby -w

TEST_DIR = File.dirname __FILE__
$: << "#{TEST_DIR}/../lib"

require 'minitest/autorun'
require 'mapi/pst'

class TestPst < Minitest::Test
	def test_attachAndInline
		load_pst "#{TEST_DIR}/pst/attachAndInline.pst"
	end

	def test_msgInMsg
		load_pst "#{TEST_DIR}/pst/msgInMsg.pst"
	end

	def test_Outlook97_2002
		load_pst "#{TEST_DIR}/pst/Outlook97-2002.pst"
	end

	def test_Outlook2003
		load_pst "#{TEST_DIR}/pst/Outlook2003.pst"
	end

	def test_200_recipients
		load_pst "#{TEST_DIR}/pst/200 recipients.pst"
	end

	def test_nonUnicodeCP932
		load_pst "#{TEST_DIR}/pst/nonUnicodeCP932.pst"
	end

	def test_unicodeAttachmentFilename
		load_pst "#{TEST_DIR}/pst/unicodeAttachmentFilename.pst"
	end

	def load_pst filename
		open filename, "r" do |f|
			pst = Mapi::Pst.new f
			pst.each do |message|
				message.to_mime
			end
		end
	end
end
