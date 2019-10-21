module raider.tools.random;

/**
 * Random number generator from Super Mario 64.
 */
ushort sm64()
{
    static ushort v;
    
    ushort a, b;
    if(v == 0x560A) v = 0;
    a = v << 8 & 0xFFFF ^ v;
    v = a << 8 & 0xFFFF | a >> 8;
    a = a << 1 & 511 ^ v; //a = (a & 255) << 1 ^ v;
    b = a >> 1 ^ 0xFF80;
    v = b ^ (a & 1 ? 0x8180 : 8180);
    if(a & 1 && b == 0xAA55) v = 0;
    
    return v;
}
