module raider.tools.memory;

import std.traits : hasMember, hasElaborateDestructor, hasElaborateCopyConstructor, 
    hasElaborateAssign, isAssignable;
import std.exception : doesPointTo;

import core.stdc.string : memcpy, memset;

enum hasPostMove(T) = is(typeof(T.init._moved()));

/**
 * Move a value, like a genteel memcpy.
 * 
 * Template parameter 'semantics' is a two-character string, and 
 * each character is either 'x' or 'm'. 'm' in the first place means the 
 * move should deconstruct the destination (if necessary) before moving. 
 * 'm' in the second place means the move should fill the source with
 * T.init (if necessary) after moving. Defaults to 'mm', resulting in 
 * semantics equivalent to std.algorithm.mutation.move.
 * 
 * Use 'x' only if the destination is uninitialised, and the source
 * won't be deconstructed according to normal scope rules.
 */
void move(string semantics = "mm", T)(ref T dst, ref T src)
{
    static if(is(T == struct))
    {
        if(&src != &dst)
        {
            //Deconstruct destination
            static if(semantics[0] != 'x' && hasElaborateDestructor!T) dst.__xdtor();
            
            //Copy memory
            static if(isAssignable!T && !hasElaborateAssign!T) dst = src;
            else memcpy(&dst, &src, T.sizeof);
            
            //Fill source with T.init 
            static if(semantics[1] != 'x' && (hasElaborateDestructor!T || hasElaborateCopyConstructor!T)) {
                enum sz = T.sizeof - (void*).sizeof * __traits(isNested, T);
                auto p = typeid(T).initializer().ptr;
                if(p) memcpy(&src, p, sz); else memset(&src, 0, sz);
            } //frustrating that this simple task requires four excessively compacted lines of code
            
            //postmove hook
            static if(hasMember!(T, "_moved")) dst._moved();
        }
    } else { dst = src; }
}

unittest
{
    struct S { uint x; }
    
    S dst_void = void;
    S dst;
    S src;
    
    move!"xm"(dst_void, src);
    move(dst, src);
}

/**
 * Swap two values.
 * 
 * Both values are assumed initialised (otherwise you want move, not swap).
 * Postmove is invoked if present.
 */
void swap(T)(ref T lhs, ref T rhs) //if (isBlitAssignable!T && !is(typeof(lhs.proxySwap(rhs))))
{
    static if(is(T == struct))
    {
        if(&lhs != &lhs)
        {
            //Swap memory
            static if(isAssignable!T && !hasElaborateAssign!T)
            {
                auto tmp = lhs;
                lhs = rhs;
                rhs = tmp;
            }
            else
            {
                ubyte[T.sizeof] tmp = void;
                memcpy(&tmp, &lhs, T.sizeof);
                memcpy(&lhs, &rhs, T.sizeof);
                memcpy(&rhs, &tmp, T.sizeof);
            }
            
            //postmove hook
            static if(hasMember!(T, "_moved"))
            {
                lhs._moved();
                rhs._moved();
            }
        }
    }
    else 
    {
        auto tmp = lhs;
        lhs = rhs;
        rhs = tmp;
    }
}

/* 5/5/2019
 * Regarding memory compaction..
 * 
 * 1. BOOKKEEPING OF REFERENCES
 * References to a moveable object join a doubly linked list of all references to that object.
 * Unmoveable objects must be statically detectable to omit the unused links.
 * The double link solves two problems: concurrent deletion, and performance concerns when deleting from very long lists (the 'many arrows' scenario).
 * The extra space required is expected to come from space left unused by a heap, even one with optimal layout.
 * 
 * Implementing the doubly linked list allows 'live' nullification of weak references and immediate memory reclamation.
 * This means the user is not required to consider the performance impact of holding onto a weak reference.
 * 
 * 2. BOOKKEEPING OF ALLOCATIONS
 * An allocation header records size in bytes, and a _moved(void*) function pointer.
 * If an array, _moved calls the _moved for its stored type. 
 * 
 * 3. BOOKKEEPING OF PAGES
 * Empty space is also allocated to fill 
 */


/* A moving allocator can afford to spend less time deciding where to allocate things initially.
 * 
 * Allocator block types
 * - I can't move, at all. Malloc me, foo!
 * - I can move as long as there aren't any strong or weak references.
 * - I am pointed at by a unique pointer found here! Check there are no strong or weak references before moving though, please c:
 * - I'm an array - gimme some slack space eh? If I don't change for a while, compact me. Unless I say otherwise.
 * 
 * A moveable type requires there to be NO pointers to it EXCEPT:
 * - A Unique reference
 * - Array data
 * - Anything updated by _moved
 * The type should probably signal intent to participate in this scheme.
 */

/*
 * A 'fat reference' system that links them into a list would be possible.
 * This adds the complexity of a lockless linked list, but that's a solved problem.
 * SORT OF. 
 * - Can't iterate the list in the presence of parallel deletions. 
 * - Can't delete without iterating the list. We need actual exclusion, which means a spinlock.
 * - The easy solution is double-linking which MIGHT be okay..? I mean it's in service of
 * reducing internal fragmentation. Wait no this doesn't actually help.
 * 
 * The key problem is iteration. If we solve that we can move on. Can broken hearts be a solution?
 * But like.. REALLY temporary broken hearts. As in, it atomically passes the task of removal to 
 * another thread (which is already in the process of performing a removal).
 * Or.. uhm.. you just use the strategies people have already mentioned. A flag in the previous wossname.
 * Better than a spinlock in the head; less contention, less time wasted. Of course it will still need
 * to spinlock, but .. eh. Also we'll need to four-byte align memory.
 * errr does this bit have to be updated whenever we iterate or what?
 * See THAT has implications. Don't want to be writing a single bit to EVERY object.
 * Won't SOMEONE think of the CACHE? Perhaps, since we have to write to decrement the refcount,
 * we can just use a spinlock in the header? Contention IS likely to be brief, and deconstruction
 * is rarely done in parallel, nor in parallel with construction.
 * 
 * Rules on spinlocks: Spin on a volatile read, not an atomic instruction, to avoid bus locks. Wossthis mean?
 * Use back-off for highly contested locks. This lock isn't highly contested.
 * Inline the loc- hahahaha.
 * Align the lock variable. No problem; the bit can be added to the header.
 * 
 * okay seriously d has a spinlock implementation just copy it
 * 
 * We could also get away with just linking the previous to the next and adding our memory
 * to a list that needs to be collected (forgotten about), but that leaves memory sitting
 * about until we collect it at the end of the frame. I don't like the idea that freed
 * memory isn't immediately available to the next request for memory. It's hot stuff.
 * It'll be in the destroying core's write cache.
 * 
 * It adds some overhead to construction of a reference (we can link to a copied
 * reference, to reduce contention). It requires a list iteration for destruction.
 * 
 * That's terrible and all, but it would improve our weak stategy. We first set it destroyed,
 * then update all the pointers - and free the memory 'immediately'.
 * 
 * This would add strong and weak references to the allowed exceptions.
 * This of course increases the percentage of moveable types to 99% of all types.
 * It also adds the rule that native references cannot be guaranteed valid over
 * frame boundaries. Whether this is an issue or not remains to be seen, but it
 * MIGHT be, if patterns are applied poorly. In which case, just set the type non-moveable..
 * Perhaps emit a warning if a moveable type holds unmanaged references (pointers, slices, natives).
 */


/* 16-6-2017
 * Regarding std.algorithm.mutation's swap and move...
 * 
 * Within the mutation module, swap and move appear to have 
 * different authors. Swap checks isBlitAssignable!T, which
 * checks its representation isMutable, ensuring T has 
 * no const or immutable memory. Meanwhile, moveEmplace (used
 * by move) doesn't check isBlitAssignable. Oh, but it does use
 * isAssignable to select between memcpy and assignment, maybe
 * for performance reasons (???) while swap uses void[] copying.
 * 
 * WHAT.
 * 
 * Oh, and move/moveEmplace balk at internal pointers, because
 * it's useful to catch things pointing at T. Even if it's only
 * catching cyclic graphs, which are sometimes valid structures.
 */
