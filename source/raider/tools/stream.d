module raider.tools.stream;

import raider.tools.reference;
import std.range;

/**
 * Takes data from somewhere, and puts it elsewhere.
 */
abstract class Stream
{private:
	string source; //Describes the remote endpoint
	string activity; //Describes what is being written or read
	uint _bytesWritten, _bytesRead;
	Mode _mode;
	Protocol _protocol;
	
public:
	enum Mode { Write, Read, Duplex }
	enum Protocol { Byte, Message }
	enum Delivery { Unreliable, Reliable, Sequential }

	this(string source, Mode mode, Protocol protocol)
	{ this.source = source; _mode = mode; _protocol = protocol; }

	@property uint bytesWritten() { return _bytesWritten; }
	@property uint bytesRead() { return _bytesRead; }
	@property bool writable() { return _mode == Mode.Write || _mode == Mode.Duplex; }
	@property bool readable() { return _mode == Mode.Read || _mode == Mode.Duplex; }
	@property Protocol protocol() { return _protocol; }

protected:
	void writeBytes(const(ubyte)[] bytes);
	void readBytes(ubyte[] bytes);

	/* Dispatches a message containing any written bytes. */
	void sendMessage(Delivery delivery);

	/* Makes a message available through readBytes.
	 * Returns false if no messages are waiting. */
	bool receiveMessage();

	uint bytesReadable();
	
	/* A note on bytesReadable
	 * 
	 * With Protocol.Byte, bytesReadable means almost nothing.
	 * 
	 * All bytestream operations are to be well-formatted with a 
	 * data-driven termination. In this protocol, bytesReadable 
	 * is only used to indicate how many bytes are immediately 
	 * available to read without readBytes blocking. It should be
	 * completely ignored in most contexts. Implementations are 
	 * free to return 0. This includes filestreams. If a file runs
	 * out during a read, that's an exception. No compromises.
	 * 
	 * With Protocol.Message it refers to the bytes remaining in a 
	 * received message, and may be used to inform read decisions.
	 * The reader must read all bytes in a message before receiving
	 * the next, or else the stream assumes an unhandled corruption.
	 * No compromises.
	 */

public:

	/**
	 * Write something to the stream.
	 * 
	 * If an item defines pack(), it will be invoked
	 * on the stream. Otherwise, it is written as it
	 * appears in memory.
	 * 
	 * All tools.reference reference types will be 
	 * dereferenced so that the referent is written 
	 * and read. When reading, they will be default
	 * constructed then unpack()'d. The same goes
	 * for native class types.
	 * 
	 * A tools.array Array will be written as an item
	 * count then an array of items. On reading, it
	 * automatically resizes and reads them back.
	 * 
	 * A native range will be written and read as if 
	 * each item were written and read separately.
	 */

	final void write(T)(const(T) that)
	{
		assert(writable);

		static if(isInstanceOf!(Array, T))
		{
			write(that.size);
			write(that[]);
		}
		else static if(isRandomAccessRange!T)
		{
			enum ET = ElementType!T;
			auto size = ET.sizeof * that.length;

			static if(hasMember!(ET, "pack"))
				foreach(ref ET p; that) p.pack(P!Stream(this));
			else
			{
				writeBytes((cast(const(ubyte)*)that.ptr)[0..size]);
				_bytesWritten += size;
			}
		}
		else write((&that)[0..1]);
	}


	final void read(T)(ref T that)
	{
		assert(readable);

		static if(isInstanceOf!(Array, T))
		{
			uint size; read(size); that.size = size;
			read(that[]);
		}
		else static if(isRandomAccessRange!T)
		{
			enum ET = ElementType!T;

			static if(is(ET == class))
				foreach(ref ET p; that) p = New!ET();

			static if(hasMember!(ET, "unpack"))
				foreach(ref ET p; that) p.unpack(P!Stream(this));
			else
			{
				auto size = ET.sizeof * that.length;
				
				if(_protocol == Protocol.Message && size > bytesReadable)
				{
					_bytesRead += bytesReadable;
					throw new StreamException("Read past end of message ("~source~", "~activity~").");
				}

				readBytes((cast(ubyte*)objects.ptr)[0..size]);
				_bytesRead += size;
			}
		}
		else read((&that)[0..1]);
	}

	final void send(Delivery delivery = Delivery.Unreliable)
	{
		assert(writable && _protocol == Protocol.Message);
		_bytesWritten = 0;
		sendMessage(delivery);
	}

	final bool receive()
	{
		assert(readable && _protocol == Protocol.Message);
		if(bytesReadable && _bytesRead) throw new StreamException("Didn't read all of message ("~source~", "~activity~").");
		scope(exit) _bytesRead = 0;
		return receiveMessage;
	}
}


import std.stdio;
version(none)
final class FileStream : Stream
{private:
	File file;
	string filename;
	
public:
	this(string filename, Mode mode)
	{
		assert(mode != Mode.Duplex);
		super(filename, mode, Frame.Byte);
		this.filename = filename;

		file = File(filename, writable ? "w" : "r");
		//const char* cstr = (filename ~ x"00").ptr;
		//file = writable ? PHYSFS_openWrite(cstr) : PHYSFS_openRead(cstr);
		
		if(file.isOpen) throw new StreamException(
			"Couldn't open file '" ~ filename ~ "' for " ~ (writable ? "writing" : "reading"));
	}
	
	~this()
	{
		try { file.close(); } catch(Exception e)
		{ throw new StreamException("Failed to close '" ~ filename ~ "'. Probably a buffered write failure."); }
	}
	
	override void writeBytes(const(ubyte)[] bytes)
	{
		if(PHYSFS_write(file, cast(const(void)*)bytes.ptr, bytes.length, 1) != 1)
			throw new StreamException("Error writing to '" ~ filename ~ "'");
	}

	override void readBytes(ubyte[] bytes)
	{
		if(PHYSFS_read(file, cast(void*)bytes.ptr, bytes.length, 1) != 1)
			throw new StreamException("Error reading from '" ~ filename ~ "'");
		if(PHYSFS_eof(file))
			throw new StreamException("EOF reading from '" ~ filename ~ "'");
	}

	override void sendMessage(Delivery d) { }
	override bool receiveMessage() { return false; }
	override uint bytesReadable() { return 0; }
}

final class SingularityStream : Stream
{
	this(Protocol p = Protocol.Byte) { super("A black hole", Mode.Write, p); }
	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
	override void sendMessage(Delivery d) { }
	override bool receiveMessage() { return false; }
	override uint bytesReadable() { return 0; }
}

/**
 * Transmits over an IP network.
 * 
 * Network streams depend on a separate networking
 * component that exposes a 'path' between hosts. 
 * Multiple streams may link through a path and are
 * very lightweight. Supports either Message or Byte.
 * 
 * Bytestream is implemented over TCP and should be 
 * used sparingly for large non-realtime transmission 
 * tasks, such as file transfer in an update client.
 * 
 * Messages use UDP and are designed for low latency
 * and low bandwidth. Ordered messages cannot replace
 * proper transmission control or effectively saturate
 * a network, but are ideal for sending small items 
 * without interrupting other realtime streams. For
 * instance, a new player's icon.
 */
final class NetworkStream : Stream
{
	this()
	{
		super("", Mode.Duplex, Protocol.Message);
	}

	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
	override void sendMessage(Delivery d) { }
	override bool receiveMessage() { return false; }
	override uint bytesReadable() { return 0; }
}

/**
 * Implements a circular buffer.
 */
final class MemoryStream : Stream
{
	this()
	{
		super("", Mode.Duplex, Protocol.Byte);
	}

	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
	override void sendMessage(Delivery d) { }
	override bool receiveMessage() { return false; }
	override uint bytesReadable() { return 0; }
}

final class StreamException : Exception
{ import raider.tools.exception; mixin SimpleThis; }
