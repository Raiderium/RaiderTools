module raider.tools.stream;

import raider.tools.reference;
import raider.tools.array;
import std.range : isRandomAccessRange, ElementType;
import std.traits : isIntegral, isInstanceOf, isSomeString, hasMember, isBoolean;
import std.conv : to;

version(BigEndian) { static assert(0, "Big endian platforms not currently supported."); }

/**
 * Takes data from somewhere, and puts it elsewhere.
 * 
 * Streams are byte-oriented, but do support writing and
 * reading individual bits. If a bytewise operation is
 * attempted on an unaligned stream, an assertion will
 * be thrown. Writing or reading unaligned bytes through
 * the bytewise interface (write and read) is prevented.
 * The bitwise interface is writeb and readb.
 */
@RC abstract class Stream
{private:
    string source; //Describes the remote endpoint
    string activity; //Describes what is being written or read
    Mode _mode;
    ubyte it, ot, ib, ob; //tags and bitcounts
    //A tag is a buffer that fills either left-to-right for big-endian streams, or right-to-left for little-endian.
    //The bitcount is how many bits are buffered.
    //Buffers are one byte to support big-endian systems / output, and to drastically simplify dsc() and pad().
    
protected: //Concrete streams implement writeBytes and readBytes
    void writeBytes(const(ubyte)[] bytes);
    void readBytes(ubyte[] bytes);
    
    //Not sure why these are protected instead of private..
    ulong _bytesWritten, _bytesRead;
    
public:
    enum Mode { Write, Read, Duplex}
    @property bool writable() { return _mode == Mode.Write || _mode == Mode.Duplex; }
    @property bool readable() { return _mode == Mode.Read || _mode == Mode.Duplex; }
    @property Mode mode() { return _mode; }
    
    //@property void blocks(bool value); //set (non)blocking
    //@property bool blocks();
    
    this(string source, Mode mode)
    {
        this.source = source;
        _mode = mode;
    }
    
    ~this()
    {
        if(writable) assert(!ob, "Stream destroyed without emitting padding.");
        if(readable) assert(!ib, "Stream destroyed without discarding input.");
    }
    
    //Bytewise interface
    @property ulong bytesWritten() { return _bytesWritten; }
    @property ulong bytesRead() { return _bytesRead; }
    
    /**
     * Write/read something to/from the stream.
     * 
     * If an item defines pack(), it will be invoked.
     * Otherwise, it is written as it appears in memory.
     * When reading, structs are initialised and classes
     * are default constructed, then unpacked.
     * 
     * Arrays and native ranges will write and read each item separately.
     * 
     * Make sure arrays are sized correctly when reading, as they
     * will read as many items as they currently contain. If a format
     * must encode a variable number of items, it is up to the
     * developer to decode the number of items, and implement sanity
     * checks to defend against intentional abuse.
     * 
     * A tools.reference.Reference will be dereferenced
     * so that the referent is written and read.
     * 
     * Any arguments provided will be passed to pack/unpack.
     */
    final void write(T, Args...)(const(T) that, auto ref Args args)
    {
        assert(writable, "Cannot write() unwritable stream.");
        assert(!ob, "Cannot write() unaligned stream.");
        
        //Array is quite similar to a Range for many intents and purposes
        static if(isInstanceOf!(Array, T) || isRandomAccessRange!T)
        {
            alias ET = ElementType!T;
            
            static if(hasMember!(ET, "pack"))
                foreach(ref ET p; that) p.pack(this, args);
            else {
                assert(args.length == 0, "Pack arguments provided for non-packable type.");
                auto size = ET.sizeof * that.length;
                writeBytes((cast(const(ubyte)*)that.ptr)[0..size]);
                _bytesWritten += size;
            }
        }
        else static if(isSomeString!T)
        {
            //This is unlikely to be compatible with wstring and such
            write(cast(ubyte[])that);
        }
        else
        {
            //Single items are fed back in as a range.
            write((&that)[0..1], args);
        }
    }
    
    ///ditto
    final void read(T, Args...)(ref T that, auto ref Args args)
    {
        assert(readable, "Cannot read() unreadable stream.");
        assert(!ib, "Cannot read() unaligned stream.");
        
        static if(isInstanceOf!(Array, T) || isRandomAccessRange!T)
        {
            alias ET = ElementType!T;
            
            static if(is(ET == class))
                foreach(ref ET p; that) p = New!ET(); //HOLD ON THIS IS A BAD IDEA
            //FIXME Check if the class is RC! Or perhaps New! can check?
            //Remove the if(isNonGCType!T) check from New and instead return a native reference?
            //What if you use R!Class blah = New!Class();?
            //I think R! should complain?
            //Yes! isReferentType will detect it and prevent the creation.
            //Nevertheless, shouldn't objects be unpackable from any state?
            //Should we only New! if the item is null?
            //That sounds right!
            
            static if(hasMember!(ET, "unpack"))
                foreach(ref ET p; that) p.unpack(this, args);
            else {
                static assert(args.length == 0, "Unused args");
                auto size = ET.sizeof * that.length;
                readBytes((cast(ubyte*)that.ptr)[0..size]);
                _bytesRead += size;
            }
        }
        else
        {
            auto tmp = (&that)[0..1];
            read(tmp, args);
        }
    }
    
    T read(T, Args...)(auto ref Args args)
    {
        T tmp; read(tmp, args);
        return tmp;
    }
    
    //Bitwise interface
    @property ulong bitsWritten() { return _bytesWritten * 8 + ob; }
    @property ulong bitsRead() { return _bytesRead * 8 + (8-ib); }
    
    ///Flush bitstream, emitting padding as necessary to align to next byte boundary.
    void pad() { if(ob) { ob = 0; write(ot); ot = 0; } }
    
    ///Discard remainder of input tag to align read to next byte boundary.
    void dsc() { ib = 0; }
    
    /**
     * Write/read in a bitwise fashion.
     * 
     * If an integer 'that' is provided, a single bit (that != 0) is written/read.
     * If integers 'that' and 'n' are provided, the least significant n bits of that are written/read.
     * 
     * If something else is provided, we behave like write/read, but
     * without enforcing alignment. Packables should use writeb if
     * they expect to be packed unaligned.
     */
    void writeb(T, Args...)(const(T) that, auto ref Args args)
    {
        assert(writable);
        
        static if((isIntegral!T || isBoolean!T) && args.length <= 1)
        {
            //Interpret a second integer argument as the number of bits to write
            static if(args.length == 1 && isIntegral!(typeof(args[0]))) {
                uint n = cast(uint)args[0];
                auto v = (n >= T.sizeof*8) ? that : that & ((1U << n) - 1); //Mask value
            } else {
                uint n = 1; //Number of bits to write
                uint v = that != 0;  //Value to write
            }

            assert(n <= T.sizeof*8, "Can't write "~to!string(n)~" bits of "~to!string(T.sizeof*8)~"-bit type. Results in out-of-range shift operations.");
            
            while(n)
            {
                //ot = output tag, ob = output bit count
                uint c = ob + n > 8 ? 8 - ob : n; //c = bits to copy
                ot |= v << ob; v >>= c;
                ob += c; n -= c; assert(ob <= 8);
                //writeBytes((cast(const(ubyte)*)ot)[0..1]);
                _bytesWritten += 1;
                if(ob == 8) { ob = 0; write(ot); ot = 0; }//uint qb = s.qb + xb;
            }
            
            /* Big-endian ('natural' output order)
            while(n)
            {
                uint c = ob + n > 8 ? 8 - ob : n; //c = bits to copy
                //copy c bits of v starting from bit n, into ot starting from bit ob
                ot |= (v >> n - c & (1 << c) - 1) << (8 - ob - c);
                ob += c; n -= c; assert(ob <= 8); if(ob == 8) { ob = 0; write(ot); ot = 0; }
            }
            */
        }
        else static if(isInstanceOf!(Array, T) || isRandomAccessRange!T)
        {
            alias ET = ElementType!T;
            
            static if(hasMember!(ET, "pack"))
                foreach(ref ET p; that) p.pack(this, args);
            else {
                static assert(args.length == 0, "Unused args");
                auto size = ET.sizeof * that.length;
                foreach(const i; (cast(ubyte*)that.ptr)[0..size]) writeb(i, 8);
            }
        }
        else writeb((&that)[0..1]);
    }
    
    ///ditto
    void readb(T, Args...)(ref T that, auto ref Args args)
    {
        assert(readable);
        
        static if((isIntegral!T || isBoolean!T) && args.length <= 1)
        {
            static if(args.length == 1 && isIntegral!(typeof(args[0])))
                uint n = cast(uint)args[0]; else uint n = 1;
            
            assert(n <= T.sizeof*8, "Can't read "~to!string(n)~" bits into "~to!string(T.sizeof*8)~"-bit type.");
            
            uint b;
            while(n)
            {
                if(ib == 0) { read(it); ib = 8; }
                uint c = n > ib ? ib : n; //c = bits to copy
                that |= cast(T)((((1 << c) - 1) & (it >> (8 - ib))) << b);
                
                ib -= c; b += c; n -= c; assert(ib <= 8);
            }
            
            /* Big-endian version
            while(n)
            {
                if(ib == 0) { read(it); ib = 8; }
                uint c = n > ib ? ib : n; //c = bits to copy
                //copy c bits of ib starting from bit ib, into that starting from bit n
                that |= (it >> ib - c & (1 << c) - 1) << n - c;
                ib -= c; n -= c; assert(ib <= 8);
            }*/
        }
        else static if(isInstanceOf!(Array, T) || isRandomAccessRange!T)
        {
            alias ET = ElementType!T;
            
            static if(is(ET == class))
                foreach(ref ET p; that) p = New!ET();
            
            static if(hasMember!(ET, "unpack"))
                foreach(ref ET p; that) p.unpack(this, args);
            else {
                static assert(args.length == 0, "Unused args");
                auto size = ET.sizeof * that.length;
                foreach(ref i; (cast(ubyte*)that.ptr)[0..size]) readb(i, 8);
            }
        }
        else
        {
            auto tmp = (&that)[0..1];
            readb(tmp, args);
        }
    }
    
    T readb(T, Args...)(auto ref Args args)
    {
        T tmp; readb(tmp, args);
        return tmp;
    }
    
    ///Skip a number of bytes.
    //void skip(ulong bytes)
    //{
    //	ubyte t;
    //	while(bytes--) read(t);
    //}
    
    //Perhaps a complementary to skip is fill()?
}

//ALL OTHER STREAMS MUST BE MOVED TO THEIR OWN FOLDERS.
//why? (6/8/2019)
//MOVE FILESTREAM TO A MODULE DEVOTED TO SANDBOXING THE FILESYSTEM.
//PREVENT USE OF UNDESIRABLE SYSTEM LIBRARIES BY NOT OFFERING THEIR INCLUDE PATHS?
//Or just scan imports for allowed paths.
//yeah but mixins.. can mixins import things?
//They can.

//This would be a feature of the build tool.
//No imports AT ALL; all entities are .. uhh.
//Having no imports would break modules.
//I guess modules will be a low-level tool.
//Perhaps a setting in the build tool.
//'Flat Codebase' - all entities are gathered into a single module with a single raider.engine import.

//'Mixins and imports are disabled for security purposes
//until an entity is added to the project explicitly.
//Adding this entity to your project file means you
//TRUST THIS CODE.'
//or something
//Or maybe we don't worry about this. At all. Are entities even the thing that will be
//shared around? I doubt this engine will ever have that sort of community.
//I doubt this engine will ever have a mod culture, either. Or do you plan on
//working out a way to bundle the compiler with games?
//Mods would absolutely need modules.. lol it's right in the name.
//Which would mean imports, and non-trivial ways to filter them.
//On the other hand, imports COULD be specified in the project file.
//That makes them easy to check. The bastion code will be required anyway for sandboxing.
//An entity could implicitly import all other modules in its folder.
//An entity WOULD implicitly import raider.engine.. no this is bad.
//It's not impossible to just .. parse imports and disallow mixins unless trusted.
//that would allow the vast majority of mods

import std.stdio : File, SEEK_END, SEEK_SET;

@RC final class FileStream : Stream
{private:
    File file;
    string filename;
    
public:
    this(string filename, Mode mode)
    {
        assert(mode != Mode.Duplex);
        //Y'know, it'd be REALLY REALLY COOL if FileStream opened lazily and write or read depending on what action was attempted.
        //It could check that filename existed first (and somehow lock it).
        //Open for reading first, check size?
        //If mode is duplex it WAITS and then each write or read .. wait. Can't files be open for both reading and writing?
        //They have only one cursor, though.
        //THAT'S FINE BY ME :D
        
        /*
         * app	(append) Set the stream's position indicator to the end of the stream before each output operation.
         * ate	(at end) Set the stream's position indicator to the end of the stream on opening.
         * binary	(binary) Consider stream as binary rather than text.
         * in	(input) Allow input operations on the stream.
         * out	(output) Allow output operations on the stream.
         * trunc	(truncate) Any current content is discarded, assuming a length of zero on opening.
         */
        //But does app not move the input cursor?
        
        super(filename, mode);
        this.filename = filename;
        
        file = File(filename, writable ? "w" : "r");
        if(!file.isOpen) throw new StreamException(
            "Couldn't open file '" ~ filename ~ "' for " ~ (writable ? "writing" : "reading"));
    }
    
    ~this()
    {
        if(writable) pad;
        if(readable) dsc;
        
        try { file.close(); } catch(Exception e)
        { throw new StreamException("Failed to close '" ~ filename ~ "'. Media disconnected?"); }
    }
    
    override void writeBytes(const(ubyte)[] bytes)
    {
        //Where's the assert(writable)?
        try { file.rawWrite(bytes); } catch(Exception e)
        { throw new StreamException("Writing to '" ~ filename ~ "' failed (file probably closed)"); }
    }
    
    override void readBytes(ubyte[] bytes)
    {
        ubyte[] tmp;
        try { tmp = file.rawRead(bytes); } catch(Exception e)
            throw new StreamException("Reading from '" ~ filename ~ "' failed (file probably closed)");
        if(tmp.length < bytes.length)
            throw new StreamException("EOF reading from '" ~ filename ~ "'");
        //TODO Should actually check EOF flag..
    }
    
    /**
     * Move the cursor a relative distance.
     */
    /* This is more effective as a function that skips bytes in all streams.
    void skip(long offset)
    {
        try { file.seek(offset, SEEK_CUR); } catch(Exception e)
            throw new StreamException("Skipping " ~ to!string(offset) ~ " bytes in '" ~ filename ~ "' failed");
    }
    */
    
    /**
     * Move the cursor to an absolute position.
     *
     * Negative offsets seek backward from the end of the file.
     */
    void seek(long offset)
    {
        try
        {
            if(offset < 0) file.seek(offset, SEEK_END);
            else file.seek(offset, SEEK_SET);
        }
        catch(Exception e)
            throw new StreamException("Seeking to absolute position " ~ to!string(offset) ~ "in '" ~ filename ~ "' failed");
        _bytesWritten = offset;
        _bytesRead = offset;
    }
    
    ulong size()
    {
        auto tmp = tell;
        try { file.seek(0, SEEK_END); } catch(Exception e)
            throw new StreamException("Finding size of file '" ~ filename ~ "' failed");
        auto result = file.tell;
        file.seek(tmp);
        return result;
    }
    
    @property ulong tell()
    {
        ulong result;
        try { result = file.tell; } catch(Exception e)
            throw new StreamException("Telling in '" ~ filename ~ "' failed");
        return result;
    }
}

@RC final class SingularityStream : Stream
{
    this() { super("A black hole", Mode.Write); }
    override void writeBytes(const(ubyte)[] bytes) { }
    override void readBytes(ubyte[] bytes) { }
    void reset() { _bytesWritten = 0; }
}

package R!SingularityStream singularity;

static this()
{
    singularity = New!SingularityStream();
}

//TODO Move NetworkStream to new library RaiderNetwork.
/**
 * Transmits over an IP network.
 * 
 * Network streams depend on a separate networking
 * system that exposes a 'path' between hosts.
 * Multiple NetworkStreams may link through a path
 * and are comparatively lightweight.
 * 
 * The networking component multiplexes content
 * from multiple NetworkStreams into a single TCP
 * socket. NetworkStreams can then be created and
 * destroyed rapidly without touching the socket.
 */
@RC final class NetworkStream : Stream
{
    this()
    {
        super("", Mode.Duplex);
    }
    
    override void writeBytes(const(ubyte)[] bytes) { }
    override void readBytes(ubyte[] bytes) { }
}

/**
 * Implements a stream in memory, optionally circular.
 * 
 * If no size is specified, the buffer grows dynamically
 * and won't loop. If a size is specified, it loops.
 */
@RC final class MemoryStream : Stream
{
    Array!ubyte buffer;
    size_t readCursor, writeCursor;
    bool loop;
    
    this(size_t size = 0)
    {
        super("", Mode.Duplex);
        buffer.size = size;
        loop = size > 0;
    }
    
    override void writeBytes(const(ubyte)[] bytes)
    {
        
    }
    
    override void readBytes(ubyte[] bytes)
    {
        
    }
}

final class StreamException : Exception
{ import raider.tools.exception; mixin SimpleThis; }


/*
 * Regarding seeking.
 * 
 * Seeking is a privilege, not a right. If a format requires seeking
 * to the end of the stream, that format is a self-obsessed layabout
 * and isn't worth our time.
 * 
 * If a format requires seeking backwards, that format is probably a
 * poorly designed format.
 */


unittest
{
    /+
    {
        auto f = New!FileStream("test.txt", Stream.Mode.Write);
        f.write!ubyte(97);
        //f.writeb(170, 8); //7 bits of 10101010 is 0101010 (42)
        
        //Write 11111011
        f.writeb(251, 7); //Only writes 1111011 (123)
        f.writeb(1234567, 32);
        /*f.writeb(3, 3);
        f.writeb(3, 2);
        f.writeb(3, 2);
        f.writeb(1);*/
    }
    
    {
        auto f = New!FileStream("test.txt", Stream.Mode.Read);
        ubyte a = f.read!ubyte;
        ubyte b = f.readb!ubyte(7);
        uint c = f.readb!uint(32);
        writeln(a);
        writeln(b);
        writeln(c);
        //assert(a == 'a');
        //assert(b == 0b101);
    }
    +/
}
