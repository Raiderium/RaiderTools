module raider.tools.compress;

import core.stdc.string : memset, memcpy;
import raider.tools.stream;
import raider.tools.huffman;

final class DeflateException : Exception
{ import raider.tools.exception; mixin SimpleThis; }

/* DEFLATE implementation adapted from tinflate.c in the tinf library.
 * tinf is by Jørgen Ibsen under the Zlib license. */

struct Tree { ushort[16] table; ushort[288] trans; }
Tree slt, sdt; ubyte[30] lbits; ushort[30] lbase; ubyte[30] dbits; ushort[30] dbase;

void build_bits_base(ubyte[] bits, ushort[] base, int d, int f) { 
    bits[0..d] = 0; foreach(i, ref b; bits[d..30]) b = cast(ubyte)(i / d);
    foreach(i; 0..30) { base[i] = cast(ushort)f; f += 1 << bits[i]; } }

void build_fixed_trees(Tree* lt, Tree* dt) {
    lt.table[0..10] = [0, 0, 0, 0, 0, 0, 0, 24, 152, 119];
    foreach(i; 0..288) lt.trans[i] = cast(ushort)(i + (i<24)*256 + (i<168)*-280 + (i<176)*136 + 144);
    dt.table[0..6] = [0, 0, 0, 0, 0, 32]; foreach(ushort i; 0..32) dt.trans[i] = i; }

void build_tree(Tree* t, const ubyte* l, uint n) {
    t.table[] = 0; foreach(i; 0..n) t.table[l[i]]++;
    t.table[0] = 0; ushort[16] offs; uint sum;
    foreach(i; 0..16) { offs[i] = cast(ushort)sum; sum += t.table[i]; }
    foreach(i; 0..n) if(l[i]) t.trans[offs[l[i]]++] = cast(ushort)i; }

shared static this() { build_fixed_trees(&slt, &sdt); //use immutable = form
    build_bits_base(lbits, lbase, 4, 3); build_bits_base(dbits, dbase, 2, 1);
    lbits[28] = 0; lbase[28] = 258; } //slt and sdt need to be immutable globals

int decode_symbol(Stream st, Tree* t) { int s, c, l; 
    do { c = c*2 + st.readb!int; l++; s += t.table[l]; c -= t.table[l]; }
    while(c >= 0); return t.trans[s + c]; }

void decode_trees(Stream s, Tree* lt, Tree* dt) {
    enum ubyte[19] clcidx = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
    uint hlit = s.readb!uint(5) + 257, hdist = s.readb!uint(5) + 1, hclen = s.readb!uint(4) + 4;
    if(hlit > 286) throw new DeflateException("HLIT > 286"); //Note that symbols 286 and 287 are part of the tree, but reserved and illegal
    if(hdist > 32) throw new DeflateException("HDIST > 32");
    if(hclen > 19) throw new DeflateException("HCLEN > 19");
    ubyte[320] lens; foreach(i; 0..hclen) lens[clcidx[i]] = s.readb!ubyte(3); 
    Tree ct; build_tree(&ct, lens.ptr, 19);
    for(uint n; n < hlit + hdist;) { int sy = decode_symbol(s, &ct); 
        if(sy == 16)      foreach(_; 0..s.readb!uint(2) +  3) lens[n++] = lens[n - 1];
        else if(sy == 17) foreach(_; 0..s.readb!uint(3) +  3) lens[n++] = 0;
        else if(sy == 18) foreach(_; 0..s.readb!uint(7) + 11) lens[n++] = 0; //Still unsure about these
        else lens[n++] = cast(ubyte)sy; }
    build_tree(lt, lens.ptr, hlit); build_tree(dt, &lens[hlit], hdist); }

//Takes a stream for input and a ubyte[] for output. Returns a range filled with uncompressed data.
ubyte[] deflate_decode(Stream s, ubyte[] dst) { uint r, bf; Tree lt, dt;
    
    void infl(Tree* lt, Tree* dt) {
        while(1) { int sym = decode_symbol(s, lt); if(sym == 256) break; if(sym < 256) { 
            if(r + 1 > dst.length) throw new DeflateException("Not enough space"); 
            dst[r++] = cast(ubyte)sym; } else { sym -= 257; int l = s.readb!int(lbits[sym]) + lbase[sym];
            int t = decode_symbol(s, dt), o = s.readb!int(dbits[t]) + dbase[t];
            if(r + l > dst.length) throw new DeflateException("Not enough space"); 
            if (r-o < 0) throw new DeflateException("Bad offset (<0)");
            foreach(_; 0..l) dst[r++] = dst[r++ - o]; } } }
    
    void infl_unc() {
        s.dsc; uint l = s.read!ushort, il = s.read!ushort; //s.read!ubyte + s.read!ubyte*256 for no endianness
        if(l != (~il & 0xFFFF)) throw new DeflateException("LEN is not !ILEN");
        if(r + l > dst.length ) throw new DeflateException("Not enough space"); 
        auto copy = dst[r..r+l]; s.read(copy); r += l; } //for(uint i = l; i; i--) *r++ = s.read!ubyte; 
    
    do { bf = s.readb!uint(1); uint bt = s.readb!uint(2);
        if(bt == 0) infl_unc; else if(bt == 1) infl(&slt, &sdt);
        else if(bt == 2) { decode_trees(s, &lt, &dt); infl(&lt, &dt); }
        else throw new DeflateException("Bad BTYPE"); } while(!bf); 
    return dst[0..r];
}

/* A compact port of libslz's rfc1951 (DEFLATE) encoder.
 * libslz is by Willy Tarreau under the X11 (MIT) license. 
 * Compared to zlib, output is 30% larger, 300% faster. */
 
//struct Stream { ulong q; uint qb, crc32, ilen; ubyte* ob; State state; }

//RFC1951 (DEFLATE) packs bits from LSB to MSB and reverses its huffman codes.
//So does WebP Lossless.

//void flush_bits(Stream* s) { if(s.qb) *s.ob++ = s.q; if(s.qb > 8) *s.ob++ = s.q >> 8;
//  if(s.qb > 16) *s.ob++ = s.q >> 16; if(s.qb > 24) *s.ob++ = s.q >> 24; s.q = 0; s.qb = 0; }

//void send_huff(Stream* s, uint c) { c = fh[c]; enq(s, c>>4, c&15); }
//void copy_16b(Stream* s, uint x) { s.ob[0] = x; s.ob[1] = x >> 8; s.ob += 2; }

/+
immutable auto len_code = (){ ushort[259] t; uint off, bits, code, len = 3;
	while(len < 259) { if(len < 11) bits = 0;
		else if(len < 19) bits = 1; else if(len <= 34) bits = 2;
		else if(len < 67) bits = 3; else if(len <= 130) bits = 4;
		else if(len < 258) bits = 5; else { code++; off = 0; bits = 0; }
		t[len] = cast(ushort)(code + (bits * 32) + (off * 256));
		off = off + 1 & (1 << bits) - 1; if(off == 0) code++; len++; } return t; }();

immutable auto fh = (){ uint[288] t; //fixed huffman table
	foreach(c; 0..288) { uint b, v; if(c < 144) { b = 8; v = 0x30 + c; }
        else if(c < 256) { b = 9; v = 0x190 + c - 144; }
		else if(c < 280) { b = 7; v = 0x00 + c - 256; } 
		else { b = 8; v = 0xC0 + c - 280; } uint r, bit = b;
		while(bit--) r += (v >> bit & 1) << (b - 1 - bit); t[c] = r * 16 + b; } return t; }();

immutable auto len_fh = (){ uint[259] t; int word, code, bits1, bits2;
	for(int mlen; mlen < 259; mlen++) { word = len_code[mlen];
		code = (word & 31) + 257; code = mlen >= 3 ? fh[code] : 0;
		bits1 = code & 15; code >>= 4; word >>= 5; bits2 = word & 7;
		if(bits2) { code |= (word >> 3) << bits1; bits1 += bits2; }
		t[mlen] = code + (bits1 << 16); } return t; }();

uint dist_to_code(uint l) { enum t = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 
	192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576];
	uint c; static foreach(const v; t) c += l > v; return c; }

uint fh_dist_table(ulong d) { uint c = dist_to_code(d + 1); uint b = c >> 1; if(b) b--;
	c = (c & 0x01) << 4 | (c & 0x02) << 2 | c & 0x04 | (c & 0x08) >> 2 | (c & 0x10) >> 4;
	c += (d & ((1 << b) - 1)) << 5; return (c << 5) + b + 5; }

long slz_rfc1951_encode(MemoryStream s, /*ubyte *dst,*/ const ubyte *src, long ilen, int more) {
	enum State : ushort { INIT, EOB, FIXED, LAST, DONE, END }
	State state;

	void copy_lit_huff(const ubyte* buf, uint len, int more) {
		if(state != State.EOB && !more) s.writeb(0, 7);
		if(state == State.EOB || !more) { 
			s.writeb(2 + !more, 3); state = more ? State.FIXED : State.LAST; }
		uint pos; while(pos < len) {uint c = fh[buf[pos++]]; s.writeb(c >> 4, c & 15); }  //send_huff(s, buf[pos++]);
	}
	
	void copy_lit(const void* buf, uint len, int more) {
		do { 
			uint len2 = len; if(len2 > 65535) len2 = 65535; len -= len2;
			if(state != State.EOB) s.writeb(0, 7); //enq(s, 0, 7); 
			state = (more || len) ? State.EOB : State.DONE;
			//enq(s, !(more || len), 3); flush_bits(s); copy_16b(s, len2); copy_16b(s, ~len2);
			s.writeb(!(more || len), 3); s.pad; s.writeb(len2, 16); s.writeb(~len2, 16);
			//memcpy(s.ob, buf, len2); s.ob += len2;
			s.write(buf[0..len2]);
		} 
		while(len); 
	}
    
	long rem = ilen; ulong pos, last; uint plit, bit9; 
	ulong[1 << HASH_BITS] refs; refs[] = -32769; s.ob = dst;
	while(rem >= 4)
	{
		uint word = *cast(uint*) &src[pos];
		uint h = ((word << 19) + (word << 6) - word) >> (32 - HASH_BITS);
		uint ent = refs[h] >> 32; last = refs[h]; refs[h] = pos + word << 32; //cast(ulong)word
		if(ent != word) { send_as_lit: rem--; plit++; pos++; 
			bit9 += cast(ubyte)word >= 144; continue; }
		if(pos - last - 1 >= 32768) goto send_as_lit;

		//uint memmatch(const ubyte* a, const ubyte* b, long max) {
		//	uint len; while(len < max) { if(a[len] != b[len]) break; len++; } return len; }
		//mlen = memmatch(src + pos + 4, src + last + 4, (rem > 258 ? 258 : rem) - 4) + 4;

		long max = (rem > 258 ? 258 : rem) - 4; auto a = src + pos + 4, b = src + last + 4;
		long mlen; while(mlen < max) { if (a[mlen] != b[mlen]) break; mlen++; } mlen += 4;

		if (bit9 >= 52 && mlen < 6) goto send_as_lit;
		uint code = len_fh[mlen]; uint dist = fh_dist_table(pos - last - 1);
		if((dist & 0x1f) + (code >> 16) + 8 >= 8 * mlen + bit9) goto send_as_lit;
		if(plit) { if (bit9 >= 52) copy_lit(s, src + pos - plit, plit, 1);
		else copy_lit_huff(s, src + pos - plit, plit, 1); plit = 0; }
		if(s.state == State.EOB) { s.state = State.FIXED; enq(s, 0x02, 3); }
		enq(s, code & 0xFFFF, code >> 16); enq(s, dist >> 5, dist & 0x1f);
		bit9 = 0; rem -= mlen; pos += mlen;
	}
	if(rem) { plit += rem; do { bit9 += cast(ubyte)src[pos++] >= 144; } while (--rem); }
	if(plit) {
		if(bit9 >= 52) copy_lit(s, src + pos - plit, plit, more);
		else copy_lit_huff(s, src + pos - plit, plit, more); plit = 0;
	}
	s.ilen+= ilen; return s.ob - dst;
}

int slz_rfc1951_finish(Stream* s, ubyte* buf) {
	s.ob = buf; if(s.state == State.FIXED || s.state == State.LAST) {
		s.state = (s.state == State.LAST) ? State.DONE : State.EOB; enq(s, 0, 7); }
	if(s.state != State.DONE) { enq(s, 3, 3); enq(s, 0, 7); s.state = State.DONE; }
	flush_bits(s); return s.ob - buf; }
+/

//Could potentially have a 'CompressStream'.
//Multiple options for headers and container combinations.
//Even if it has to buffer the output, we write to and read from arbitrary streams.
//MemoryStream can be used simply as an interior tool.

//replace all of this with the bitstream
//I could probably add my own error-checking here..
//Look through official deflate for all error return points 

//Should each compressor be contained in a struct?
//With consistent interfaces?

//Start by getting everything working.
//Need to replace slz's FH with TINF's fixed huffman trees. They are the same data.
//But, is there an advantage to the flipped huffman bits? 
//Should that advantage be linked to tinf? 
//They are written in reverse bit order in send_huff..

/* I WILL IMPLEMENT THE ZLIB HEADER-TRAILER MYSELF.
 * This stuff is REALLY confusing.
 * 
 * 1950_encode:
 * 	1950_send_header
 * 	adler the block
 * 	1951_encode
 * 
 * 1950 send header: copy two bytes
 * 
 * 1950_finish:
 *  For some reason, docs say sends gzip trailer, but actually is gzip header if still init state.
 *  (Well, perhaps it's a way to write a valid null output?)
 *  1951_finish
 *  writes adler big-endian
 * 
 * It might be possible to shift the refs backward (invalidating as necessary)
 * to get the benefits of streaming.
 * 
 * NO because the CHUNK LENGTH COMES FIRST. You mook.
 */
 

/+
/* A compact port of SR2 (symbol ranking compressor).
 * SR2 is by Matt Mahoney under the GPL.
 * For fast general-purpose compression. */

immutable auto dt = (){ int[128] t; foreach(i; 0..128) t[i] = 512/(i+2); } ();
enum N = (1024+64)*258;

struct StateMap { uint[N] t; this() { t[] = 1<<31; } int p(int c) { return t[c] >> 20; }
	void update(int c, int y) { int n = t[c] & 127, p = t[c] >> 9; 
		if(n < 127) t[c]++; t[c] += ((y << 23) - p) * dt[n] & 0xFFFFFF80; } 
}

struct Encoder_SR2 { 
	Stream* s; uint x1, x2 = ~0; StateMap sm; 

	void code(int c, int y) {
		int p = sm.p(c);
		uint xmid = x1 + (x2 - x1 >> 12) * p;
		if(y) x2 = xmid; else x1 = xmid + 1;
        sm.update(c, y);
		while(((x1 ^ x2) & 0xFF000000) == 0) {
			//putc(x2 >> 24, archive);
			x1 <<= 8; x2 = (x2 << 8) + 255;
		}
	}

	void flush() { /*putc(x1 >> 24, archive); */ }
}

void sr2_encode(ref Encoder e, int cxt, int c) {
	int b = (c >> 4) + 16; 
	e.code(cxt+1     , b>>3&1); e.code(cxt+(b>>3), b>>2&1);
	e.code(cxt+(b>>2), b>>1&1); e.code(cxt+(b>>1), b   &1);

	cxt += 15 * (b - 15); b = c & 15 | 16;
	e.code(cxt+1     , b>>3&1); e.code(cxt+(b>>3), b>>2&1);
	e.code(cxt+(b>>2), b>>1&1); e.code(cxt+(b>>1), b   &1);
}
+/

/* A compact port of RANS.
 * Adapted code placed in the public domain by Fabian 'ryg' Giesen 2014.
 */
//Bite this bullet: RE requires 64-bit.
//Look up d-gamedev-team/gfm. It's been simplified.
//Compare vec classes.
//Compare mat4 inversion.

immutable uint RANS_BYTE_L = 1 << 23;
void put(ref uint state, ubyte** pptr, uint start, uint freq, uint scale_bits)
{
	
}
