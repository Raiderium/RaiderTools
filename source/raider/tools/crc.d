module raider.tools.crc;

immutable auto crc32 = ()
{
    uint[256] t;
    foreach(uint n; 0..256) {
        uint c = n;
        foreach(_; 0..8)
            if(c & 1) c = 0xEDB88320 ^ (c >> 1);
            else c >>= 1;
        t[n] = c;
    }
    return t;
}();

struct CRC32
{
    uint c = 0;
    
    void add(const ubyte b)
    {
        c = ~c;
        c = crc32[(c ^ b) & 0xFF] ^ (c >> 8);
        c = ~c;
    }
}

struct Adler32
{
    uint c = 1;
    
    void add(const ubyte b)
    {
        uint a = c & 0xFFFF, s = c >> 16;
        a += b; if(a >= 65521) a -= 65521; //dear branch prediction,
        s += a; if(s >= 65521) s -= 65521; //thank you for existing
        //(assuming the compiler actually emits branches here, of course)
        c = a | s << 16;
    }
}

/*
void crc32(Args...)(ref uint c, Args args)
{
    c = ~c;
    foreach(arg; args) {
        static if(isRandomAccessRange!(typeof(arg)))
            auto buf = (cast(ubyte*)arg.ptr)[0..arg.length];
        else auto buf = (cast(ubyte*)&arg)[0..arg.sizeof];
        foreach(b; buf)
            c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    c = ~c;
}

void adler32(Args...)(ref uint c, Args args)
{
    foreach(arg; args) {
        static if(isRandomAccessRange!(typeof(arg)))
            auto buf = (cast(ubyte*)arg.ptr)[0..arg.length];
        else auto buf = (cast(ubyte*)&arg)[0..arg.sizeof];
    }
}
*/
