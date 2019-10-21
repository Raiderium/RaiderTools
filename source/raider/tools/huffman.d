module raider.tools.huffman;

import raider.tools.array;
import raider.tools.stream;

/**
 * Huffman code manipulation, using an algorithm implemented in the tinf library.
 * tinf is by Jørgen Ibsen under the zlib license. 
 * https://github.com/jibsen/tinf/blob/master/src/tinflate.c
 * 
 * Supports 16-bit code lengths and symbols, and reads in a manner compatible
 * with WebP. Reads bit-by-bit and stops precisely when it should. Note this
 * is not entirely compatible with DEFLATE - it handles single-leaf trees
 * with a zero-length code, not by adding an unused code.
 * 
 * This module does not implement any format-specific routines. Formats will
 * need to provide a list of canonical code lengths. */

final class HuffmanException : Exception
{ import raider.tools.exception; mixin SimpleThis; }

alias HE = HuffmanException;

struct Tree {
    ushort[16] hist; //Code length histogram
    Array!ushort symbols; //Symbols sorted by code
    int max_sym;
    
    //Build a tree from canonical code lengths 
    void build(const ubyte[] le) { 
        hist[] = 0; max_sym = -1; ushort[16] offs; uint sum, ava = 1; 
        foreach(i, l; le) { assert(l < 16); if(l) { max_sym = i; hist[l]++; } }
        foreach(h; hist) { if(h > ava) throw new HE("Bad code lengths"); ava = (ava - h)*2; }
        foreach(i; 0..16) { offs[i] = cast(ushort)sum; sum += hist[i]; }
        if((sum > 1 && ava) || (sum == 1 && hist[1] != 1)) throw new HE("Bad code lengths");
        symbols.length = sum; symbols[] = 0;
        //symbols.length = (sum == 1 ? 2 : sum); symbols[] = 0; // DEFLATE compatibility
        foreach(i, l; le) if(l) symbols[offs[l]++] = cast(ushort)i;
        //if(sum == 1) { hist[1] = 2; symbols[1] = cast(ushort)(max_sym + 1); } } // DEFLATE compatibility
    }
    
    //Get the next symbol from a stream
    uint next(Stream st) { int b, o, l = 1;
        if(symbols.length == 1) return symbols[0]; // WEBP compatibility
        while(1) { assert(l < 16); o = o*2 + st.readb!int; 
            auto h = hist[l++]; if(o < h) break; b += h; o -= h; } 
        assert(b + o >= 0 && b + o < symbols.length); return symbols[b + o]; }
    
    //Build a tree from symbol frequencies
    void build(const ushort[] hist)
    {
        
    }
}
