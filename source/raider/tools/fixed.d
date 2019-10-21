module raider.tools.fixed;

/* Fixed-point math.
 * Experimental.
 * Perhaps can take advantage of other CPU resources while FPU is busy.
 * 
 * Using Q16 fixed-point for rotation matrices has the following advantages.
 * - Half-size for less ram consumption
 * - Half-size for better cache performance
 * - Faster? (Should be!)
 * - No wasted exponent bits
 * - Convert to float with shift + mask?
 * 
 * Question: Is dividing a float/double by a po2 'fast'?
 * Of course, 
 * All questions come down to fixed * float, for mat * vec performance.
 * If it's minimal overhead, good - implement fixed later
 * for a full system test.
 */

/* Quaternions with chebyshev approximation? Distribute values better..? */

struct Fixed
{
    short f;
}

//Fixed!"1.15"   Signed 
//Fixed!"U1.15"  Unsigned
//Fixed!"16"     Unsigned (no integer bit)
//Fixed!"U16"    Unsigned (redundant U)

//TODO Quaternion compression - omit largest (2 bits to specify) then encode remaining in 10 bits between +0.7071, -0.7071
//Also position compression - transmit only bits that have changed, adding six bits overhead (64)
//There are 8 bytes.
//4 bits - how many low nybbles have changed
//4 bits - a specific high nybble that has changed
//Underlap nybbles are set to 0. Overlap nybbles are set to 1, and meaning is reversed.
//If the same, no high nybble is specified in payload.

//Velocity - same as position!
//This won't work without a shadow variable (otherwise client *polation can change unchanged bits)
//This is a tradeoff - packet loss causes errors. Stagger full updates to correct.
//that is NOT impossible.. and it's a HUGE advantage for network bandwidth.
//This can even work for quaternions.
//No-update tech should be implemented, though. It was always going to need shadow bits.
//Spikes in high ranges.. around these spikes a lot of bits are 1 or 0.
//5 bits: Highest 16 bits

