module awkcc.strpool;

import awkcc.arena;
import awkcc.util : isPowerOfTwo;

import core.stdc.string : memcmp;
import core.stdc.stdint : uint32_t, uint64_t;
import std.algorithm : max;

/**
 * String interning pool.
 *
 * - All strings are stored in an Arena
 * - Interned strings have s_table identity
 * - Pointer equality may be used to compare symbols
 */
struct StringPool
{
    private Arena* _arena;

    private Entry* _table;
    private size_t _capacity;
    private size_t _count;

    /// Load factor threshold (0.75)
    enum LOAD_NUM = 3;
    enum LOAD_DEN = 4;

    /// Initial _table size (must be power of two)
    enum INITIAL_CAPACITY = 1024;

    /**
     * Intern _table entry.
     */
    private struct Entry
    {
        const(char)* ptr;
        size_t len;
        uint64_t hash;
    }

    @disable this(this);

    /**
     * Create a string pool using the given arena.
     */
    static StringPool create(Arena* arena, size_t initialCapacity = INITIAL_CAPACITY)
    {
        assert(arena !is null);
        assert(isPowerOfTwo(initialCapacity));

        StringPool pool = StringPool.init;
        pool._arena = arena;
        pool._capacity = initialCapacity;
        pool._count = 0;
        pool._table = cast(Entry*) arena.calloc(Entry.sizeof * initialCapacity, Entry.alignof);

        return pool;
    }

    /**
     * Intern a string slice.
     *
     * Returns a canonical string whose lifetime
     * is bound to the _arena.
     */
    string intern(const(char)[] s)
    {
        if (s.length == 0)
            return "";

        if ((_count + 1) * LOAD_DEN >= _capacity * LOAD_NUM)
            rehash(_capacity * 2);

        uint64_t h = hashString(s);
        size_t mask = _capacity - 1;
        size_t i = cast(size_t) h & mask;

        for (;;)
        {
            Entry* e = &_table[i];

            if (e.ptr is null)
            {
                // New entry
                auto dup = _arena.dupString(s);
                e.ptr = dup.ptr;
                e.len = dup.length;
                e.hash = h;
                _count++;
                return dup;
            }

            if (e.hash == h && e.len == s.length && memcmp(e.ptr, s.ptr, s.length) == 0)
            {
                // Existing interned string
                return cast(string) e.ptr[0 .. e.len];
            }

            i = (i + 1) & mask;
        }
    }

    /**
     * Reset the pool (does NOT free _arena memory).
     *
     * Typically used together with _arena.reset().
     */
    void reset()
    {
        for (size_t i = 0; i < _capacity; ++i)
        {
            _table[i].ptr = null;
            _table[i].len = 0;
            _table[i].hash = 0;
        }
        _count = 0;
    }

    /**
     * Number of interned strings.
     */
    @property size_t size() const pure
    {
        return _count;
    }

    /**
     * Rehash the _table to a larger size.
     */
    private void rehash(size_t newCapacity)
    {
        assert(isPowerOfTwo(newCapacity));

        Entry* oldTable = _table;
        size_t oldCap = _capacity;

        _table = cast(Entry*) _arena.calloc(Entry.sizeof * newCapacity, Entry.alignof);
        _capacity = newCapacity;
        _count = 0;

        foreach (i; 0 .. oldCap)
        {
            auto e = oldTable[i];
            if (e.ptr !is null)
            {
                insertExisting(e);
            }
        }
    }

    /**
     * Insert an existing entry during rehash.
     */
    private void insertExisting(Entry e)
    {
        size_t mask = _capacity - 1;
        size_t i = cast(size_t) e.hash & mask;

        for (;;)
        {
            Entry* dst = &_table[i];
            if (dst.ptr is null)
            {
                *dst = e;
                _count++;
                return;
            }
            i = (i + 1) & mask;
        }
    }

    /**
     * 64-bit FNV-1a hash (fast, good enough for symbols).
     */
    private static uint64_t hashString(const(char)[] s) pure @safe
    {
        uint64_t h = 1469598103934665603UL;
        foreach (c; s)
        {
            h ^= cast(ubyte) c;
            h *= 1099511628211UL;
        }
        return h;
    }
}

unittest
{
    import std.stdio : writeln;

    auto arena = Arena.create();
    scope (exit)
        arena.destroy();

    auto pool = StringPool.create(&arena);

    auto a = pool.intern("hello");
    auto b = pool.intern("hello");
    auto c = pool.intern("world");

    assert(a.ptr == b.ptr);
    assert(a == b);
    assert(a != c);

    assert(pool.size == 2);

    writeln("StringPool tests passed");
}
