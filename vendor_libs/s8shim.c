// Shim for Q-era vendor blobs: android::String8::String8(StaticLinkage)
// was removed from A16 libutils. Replicates the Q semantics (mString =
// immortal empty SharedBuffer) using the REAL SharedBuffer::alloc so the
// layout matches whatever libutils is loaded (v45).
extern void* _ZN7android12SharedBuffer5allocEm(unsigned long size);

// Q SharedBuffer layout: { atomic<int32> mRefs; size_t mSize; char m_data[1]; }
// data() = buf + 16 on LP64. alloc() returns refs=1; bump to 2 so a release
// from the consumer never frees the immortal empty string.
void _ZN7android7String8C1ENS0_13StaticLinkageE(void* self, int sl) {
    (void)sl;
    void* buf = _ZN7android12SharedBuffer5allocEm(1);
    if (buf) {
        __atomic_add_fetch((int*)buf, 1, __ATOMIC_SEQ_CST);
        char* p = (char*)buf + 16;
        p[0] = '\0';
        *(const char**)self = p;
    } else {
        *(const char**)self = 0;
    }
}
