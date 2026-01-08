module awkcc.arena;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memset, memcpy;
import std.algorithm : max;

/**
 * Arena allocator for fast bump-pointer allocation.
 * 
 * Allocations are extremely fast (just pointer bump).
 * Memory is freed all at once when the arena is reset or destroyed.
 * Individual deallocations are not supported.
 */
struct Arena
{
    private Slab* _currentSlab;
    private Slab* _firstSlab;
    private size_t _slabSize;
    private size_t _totalAllocated;
    private size_t _totalCapacity;

    // Statistics
    private size_t _numSlabs;
    private size_t _numAllocations;
    private size_t _peakUsage;

    /**
     * Slab header.
     */
    private struct Slab
    {
        Slab* next;
        size_t capacity;
        size_t used;

        // Data follows header (flexible array member simulation)
        ubyte* data() return @trusted
        {
            return cast(ubyte*)(cast(void*)&this + Slab.sizeof);
        }
    }

    /**
     * Default slab size (64 KB).
     */
    enum DEFAULT_SLAB_SIZE = 64 * 1024;

    /**
     * Minimum slab size (4 KB).
     */
    enum MIN_SLAB_SIZE = 4 * 1024;

    /**
     * Default alignment.
     */
    enum DEFAULT_ALIGNMENT = 16;

    @disable this(this); // No copying

    /**
     * Initialize arena with given slab size.
     */
    static Arena create(size_t _slabSize = DEFAULT_SLAB_SIZE)
    {
        Arena arena;
        arena._slabSize = max(_slabSize, MIN_SLAB_SIZE);
        arena._currentSlab = null;
        arena._firstSlab = null;
        arena._totalAllocated = 0;
        arena._totalCapacity = 0;
        arena._numSlabs = 0;
        arena._numAllocations = 0;
        arena._peakUsage = 0;
        return arena;
    }

    /**
     * Destroy arena and free all memory.
     */
    void destroy() @trusted
    {
        Slab* slab = _firstSlab;
        while (slab !is null)
        {
            Slab* next = slab.next;
            free(slab);
            slab = next;
        }

        _currentSlab = null;
        _firstSlab = null;
        _totalAllocated = 0;
        _totalCapacity = 0;
        _numSlabs = 0;
    }

    /**
     * Allocate memory from arena.
     */
    void* alloc(size_t size, size_t alignment = DEFAULT_ALIGNMENT) @trusted
    {
        if (size == 0)
            return null;

        // Ensure alignment is power of 2
        assert((alignment & (alignment - 1)) == 0, "Alignment must be power of 2");

        // Try current slab
        if (_currentSlab !is null)
        {
            void* ptr = allocFromSlab(_currentSlab, size, alignment);
            if (ptr !is null)
            {
                _numAllocations++;
                _totalAllocated += size;
                _peakUsage = max(_peakUsage, _totalAllocated);
                return ptr;
            }
        }

        // Need new slab
        size_t newSlabSize = max(_slabSize, size + alignment + Slab.sizeof);
        Slab* newSlab = createSlab(newSlabSize);

        if (newSlab is null)
            return null;

        // Link new slab
        newSlab.next = _firstSlab;
        _firstSlab = newSlab;
        _currentSlab = newSlab;
        _numSlabs++;
        _totalCapacity += newSlab.capacity;

        // Allocate from new slab
        void* ptr = allocFromSlab(newSlab, size, alignment);
        if (ptr !is null)
        {
            _numAllocations++;
            _totalAllocated += size;
            _peakUsage = max(_peakUsage, _totalAllocated);
        }

        return ptr;
    }

    /**
     * Allocate and zero-initialize memory.
     */
    void* calloc(size_t size, size_t alignment = DEFAULT_ALIGNMENT) @trusted
    {
        void* ptr = alloc(size, alignment);
        if (ptr !is null)
        {
            memset(ptr, 0, size);
        }

        return ptr;
    }

    /**
     * Allocate typed memory.
     */
    T* allocType(T)(size_t count = 1) @trusted
    {
        return cast(T*) alloc(T.sizeof * count, T.alignof);
    }

    /**
     * Allocate and initialize typed memory.
     */
    T* allocInit(T, Args...)(Args args) @trusted
    {
        T* ptr = allocType!T();
        if (ptr !is null)
        {
            import core.lifetime : emplace;

            emplace(ptr, args);
        }

        return ptr;
    }

    /**
     * Allocate array.
     */
    T[] allocArray(T)(size_t count) @trusted
    {
        if (count == 0)
            return [];

        T* ptr = cast(T*) alloc(T.sizeof * count, T.alignof);
        if (ptr is null)
            return [];

        return ptr[0 .. count];
    }

    /**
     * Duplicate a string.
     */
    string dupString(const(char)[] str) @trusted
    {
        if (str.length == 0)
            return "";

        char* ptr = cast(char*) alloc(str.length + 1, 1);
        if (ptr is null)
            return "";

        memcpy(ptr, str.ptr, str.length);
        ptr[str.length] = '\0';

        return cast(string) ptr[0 .. str.length];
    }

    /**
     * Reset arena (free all allocations but keep slabs).
     */
    void reset() @trusted
    {
        // Reset all slabs
        Slab* slab = _firstSlab;
        while (slab !is null)
        {
            slab.used = 0;
            slab = slab.next;
        }

        _currentSlab = _firstSlab;
        _totalAllocated = 0;
        _numAllocations = 0;
    }

    /**
     * Create a save point (marker).
     */
    ArenaMarker mark()
    {
        return ArenaMarker(_currentSlab, _currentSlab ? _currentSlab.used : 0, _totalAllocated);
    }

    /**
     * Restore to a save point.
     */
    void restore(ArenaMarker marker) @trusted
    {
        // Free slabs allocated after marker
        while (_firstSlab !is null && _firstSlab !is marker.slab)
        {
            Slab* next = _firstSlab.next;
            _totalCapacity -= _firstSlab.capacity;
            _numSlabs--;
            free(_firstSlab);
            _firstSlab = next;
        }

        _currentSlab = marker.slab;

        if (_currentSlab !is null)
        {
            _currentSlab.used = marker.used;
        }

        _totalAllocated = marker._totalAllocated;
    }

    /**
     * Get statistics.
     */
    ArenaStats stats() const
    {
        return ArenaStats(_totalAllocated, _totalCapacity, _numSlabs, _numAllocations, _peakUsage);
    }

    /**
     * Allocate from a specific slab.
     */
    private void* allocFromSlab(Slab* slab, size_t size, size_t alignment) @trusted
    {
        // Align current position
        size_t current = cast(size_t) slab.data + slab.used;
        size_t aligned = alignUp(current, alignment);
        size_t offset = aligned - cast(size_t) slab.data;

        // Check if fits
        if (offset + size > slab.capacity)
            return null;

        slab.used = offset + size;
        return cast(void*) aligned;
    }

    /**
     * Create a new slab.
     */
    private Slab* createSlab(size_t minCapacity) @trusted
    {
        size_t dataCapacity = max(minCapacity, _slabSize);
        size_t totalSize = Slab.sizeof + dataCapacity;

        Slab* slab = cast(Slab*) malloc(totalSize);
        if (slab is null)
            return null;

        slab.next = null;
        slab.capacity = dataCapacity;
        slab.used = 0;

        return slab;
    }

    /**
     * Align value up to alignment.
     */
    private static size_t alignUp(size_t value, size_t alignment) pure @safe
    {
        return (value + alignment - 1) & ~(alignment - 1);
    }
}

/**
 * Arena marker for save/restore.
 */
struct ArenaMarker
{
    private Arena.Slab* slab;
    private size_t used;
    private size_t _totalAllocated;
}

/**
 * Arena statistics.
 */
struct ArenaStats
{
    size_t allocated;
    size_t capacity;
    size_t numSlabs;
    size_t numAllocations;
    size_t _peakUsage;

    /**
     * Get utilization percentage.
     */
    double utilization() const
    {
        if (capacity == 0)
            return 0.0;
        return cast(double) allocated / cast(double) capacity * 100.0;
    }
}

/**
 * Scoped arena - automatically resets on scope exit.
 */
struct ScopedArena
{
    private Arena* arena;
    private ArenaMarker marker;

    @disable this();
    @disable this(this);

    this(ref Arena arena)
    {
        this.arena = &arena;
        this.marker = arena.mark();
    }

    ~this()
    {
        if (arena !is null)
        {
            arena.restore(marker);
        }
    }

    /**
     * Allocate from _scoped arena.
     */
    void* alloc(size_t size, size_t alignment = Arena.DEFAULT_ALIGNMENT)
    {
        return arena.alloc(size, alignment);
    }

    T* allocType(T)(size_t count = 1)
    {
        return arena.allocType!T(count);
    }

    T[] allocArray(T)(size_t count)
    {
        return arena.allocArray!T(count);
    }
}

/**
 * Thread-local arena for temporary allocations.
 */
Arena* threadArena()
{
    static Arena arena;
    static bool initialized = false;

    if (!initialized)
    {
        arena = Arena.create();
        initialized = true;
    }

    return &arena;
}

/**
 * Temporary allocation scope using thread-local arena.
 */
struct TempAlloc
{
    private ScopedArena _scoped;

    @disable this();
    @disable this(this);

    static TempAlloc create()
    {
        TempAlloc t = TempAlloc.init;
        t._scoped = ScopedArena(*threadArena());
        return t;
    }

    void* alloc(size_t size)
    {
        return _scoped.alloc(size);
    }

    T* allocType(T)(size_t count = 1)
    {
        return _scoped.allocType!T(count);
    }

    T[] allocArray(T)(size_t count)
    {
        return _scoped.allocArray!T(count);
    }
}

unittest
{
    auto arena = Arena.create(4096);
    scope (exit)
        arena.destroy();

    auto p1 = arena.alloc(100);
    assert(p1 !is null);

    auto p2 = arena.alloc(200);
    assert(p2 !is null);
    assert(p1 != p2);

    auto p3 = arena.alloc(1, 64);
    assert((cast(size_t) p3 & 63) == 0);

    auto intPtr = arena.allocType!int(10);
    assert(intPtr !is null);
    intPtr[0] = 42;
    intPtr[9] = 99;
    assert(intPtr[0] == 42);
    assert(intPtr[9] == 99);

    auto str = arena.dupString("Foo bar");
    assert(str == "Foo bar");

    auto marker = arena.mark();
    arena.alloc(1000);
    arena.alloc(2000);
    assert(arena.stats().allocated > 0);
    arena.restore(marker);
    assert(arena.stats().allocated > 300);

    import std.stdio : writeln;

    writeln("Arena test suite 1 passed");
}
