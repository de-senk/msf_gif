
/*
HOW TO USE:

    In exactly one translation unit (.c or .cpp file), #define MSF_GIF_IMPL before including the header, like so:

    #define MSF_GIF_IMPL
    #include "msf_gif.h"

    Everywhere else, just include the header like normal.


USAGE EXAMPLE:

    int width = 480, height = 320, centisecondsPerFrame = 5, quality = 16;
    MsfGifState gifState = {};
    // msf_gif_bgra_flag = true; //optionally, set this flag if your pixels are in BGRA format instead of RGBA
    // msf_gif_alpha_threshold = 128; //optionally, enable transparency (see function documentation below for details)
    msf_gif_begin(&gifState, width, height);
    msf_gif_frame(&gifState, ..., centisecondsPerFrame, quality, width * 4); //frame 1
    msf_gif_frame(&gifState, ..., centisecondsPerFrame, quality, width * 4); //frame 2
    msf_gif_frame(&gifState, ..., centisecondsPerFrame, quality, width * 4); //frame 3, etc...
    MsfGifResult result = msf_gif_end(&gifState);
    if (result.data) {
        FILE * fp = fopen("MyGif.gif", "wb");
        fwrite(result.data, result.dataSize, 1, fp);
        fclose(fp);
    }

    msf_gif_free(result);

Detailed function documentation can be found in the header section below.


ERROR HANDLING:

    If memory allocation fails, the functions will signal the error via their return values.
    If one function call fails, the library will free all of its allocations,
    and all subsequent calls will safely no-op and return 0 until the next call to `msf_gif_begin()`.
    Therefore, it's safe to check only the return value of `msf_gif_end()`.


REPLACING MALLOC:

    This library uses malloc+realloc+free internally for memory allocation.
    To facilitate integration with custom memory allocators, these calls go through macros, which can be redefined.
    The expected function signature equivalents of the macros are as follows:

    void * MSF_GIF_MALLOC(void * context, msf_size_t newSize)
    void * MSF_GIF_REALLOC(void * context, void * oldMemory, msf_size_t oldSize, msf_size_t newSize)
    void MSF_GIF_FREE(void * context, void * oldMemory, msf_size_t oldSize)

    If your allocator needs a context pointer, you can set the `customAllocatorContext` field of the MsfGifState struct
    before calling msf_gif_begin(), and it will be passed to all subsequent allocator macro calls.

    The maximum number of bytes the library will allocate to encode a single gif is bounded by the following formula:
    `(2 * 1024 * 1024) + (128 * 1024) + (width * height * 8) + ((2048 + width * height * 1.5) * 2 * frameCount)`
    The peak heap memory usage in bytes, if using a general-purpose heap allocator, is bounded by the following formula:
    `(2 * 1024 * 1024) + (128 * 1024) + (width * height * 11) + 2048 + (16 * frameCount) + (2 * sizeOfResultingGif)


See end of file for license information.
*/

//version 2.4
msf_size_t :: s64;

MsfGifResult :: struct {
    data: *void;
    dataSize: msf_size_t;

    allocSize: msf_size_t; //internal use
    contextPointer: *void; //internal use
} ;

MsfCookedFrame :: struct { //internal use
    pixels: *u32;
    depth, count, rbits, gbits, bbits: int;
} ;

MsfGifBuffer :: struct { //internal use
    next: *#this; //*MsfGifBuffer
    size: msf_size_t;
    data: [1]u8;
} ;

MsfGifState :: struct { //internal use
    fileWriteFunc         :  type_of(MsfGifFileWriteFunc);
    fileWriteData         : *void;
    previousFrame         :  MsfCookedFrame;
    currentFrame          :  MsfCookedFrame;
    lzwMem                : *s16;
    tlbMem                : *u8;
    usedMem               : *u8;
    listHead              : *MsfGifBuffer;
    listTail              : *MsfGifBuffer;
    width, height         :  int;
    customAllocatorContext: *void;
    framesSubmitted       :  int; //needed for transparency to work correctly (because we reach into the previous frame)
} ;

#scope_module
#import "Basic";
bitops ::#import "Bit_Operations";

// msf_bit_log :: inline (i: int) -> int { return 32 - __builtin_clzl(i); }
// msf_bit_log :: inline (i: int) -> int { return 1 + bitops.bit_scan_reverse(i);} //maybe bit_scan_forward == 32 - bit_scan_reverse?
msf_bit_log :: inline (i_unmutable: int) -> int {
    i:= i_unmutable;
    MultiplyDeBruijnBitPosition :[32]int : int.[
        0, 9, 1, 10, 13, 21, 2, 29, 11, 14, 16, 18, 22, 25, 3, 30,
        8, 12, 20, 28, 15, 17, 24, 7, 19, 27, 23, 6, 26, 5, 4, 31,
    ];

    i |= i >> 1;
    i |= i >> 2;
    i |= i >> 4;
    i |= i >> 8;
    i |= i >> 16;
    // return MultiplyDeBruijnBitPosition[cast(u32)(cast(u32)i * cast(u32)0x07C4ACDD) >> 27] + 1;
    // return MultiplyDeBruijnBitPosition[cast(u32)(i * 0x07C4ACDD) >> 27] + 1;
    return MultiplyDeBruijnBitPosition[cast(u32)(cast(u32)i * 0x07C4ACDD) >> 27] + 1;

}
/*
#run {
test_values: [20]int = int.[
        0,
        1, 2, 3, 4, 5, 6, 7,
        8, 15, 16, 31, 32,
        63, 64, 127, 128,
        1023, 1024,
        0x7FFFFFFF // INT_MAX (31-bit ones)
    ];

    for v: test_values {
        // compute reference: floor(log2(v)) + 1 for v>0.
        expected := 0;
        if (v == 0) {
            // match current implementation behaviour
            expected = 1;
        } else {
            t := v;
            while (t > 0) {
                expected += 1;
                t >>= 1;
            }
        }

        got := msf_bit_log(v);
        if (got != expected) {
            print("FAIL: v=% d got=% d expected=% d\n", v, got, expected);
            assert(false);
        } else {
            print("OK: v=% d -> % d\n", v, got);
        }
    }

}
*/


// typedef msf_size_t (* MsfGifFileWriteFunc) (const void * buffer, msf_size_t size, msf_size_t count, void * stream);
// typedef msf_size_t (* MsfGifFileWriteFunc) (const void * buffer, msf_size_t size, msf_size_t count, void * stream);

MsfGifFileWriteFunc :: (buffer: *void, size: msf_size_t, count: msf_size_t, stream: *void) ->  msf_size_t {

    return 0;
}



offset_of :: ($T: Type, $member: string) -> int {
    for type_info(T).members {
        if it.name == member return it.offset_in_bytes;
    }

    assert(false, "Type '%' does not have member '%'", T, member);
    return -1;
}

#scope_export
// #if #exists(__IPROF) #load "examples/example1.jai";

msf_gif_begin :: (handle: *MsfGifState, width: int, height: int) -> int {
    //profiler->MsfTimeFunc
    //To help avoid potential overflow errors, let's just not even try to support images larger than 1GB in size.
    //And let's also reject images with width or height more or less than what the gif format itself supports.
    MAX_PIXELS :: 268435456; //2^30 / 4 = 1GB / bytesPerPixel
    if width < 1 || height < 1 || width > 65535 || height > 65535 || width >= MAX_PIXELS / height {
        handle.listHead = null; //this implicitly marks the handle as invalid until the next msf_gif_begin() call
        return 0;
    }

    //NOTE: we cannot stomp the entire struct to zero because we must preserve `customAllocatorContext`.
    empty: MsfCookedFrame;// LOL, me too! OAuthor comment:-> = {0}; //god I hate MSVC...
    handle.previousFrame = empty;
    handle.currentFrame = empty;
    handle.width = width;
    handle.height = height;
    handle.framesSubmitted = 0;

    //NOTE: Default stack sizes for some platforms are very small. Emscripten in particular uses a 64k stack by default.
    //      So anything that large or larger must be allocated on the heap, even if its maximum size is compile-time known.
    //      The `lzw`, `tlb`, and `used` arrays are 2MB, 64KB, and 64KB respectively, so we allocate them here.
    //      We could make them arrays at global scope, but that would create problems if the library is used from multiple threads.
    // handle.lzwMem = (s16 *) MSF_GIF_MALLOC(handle.customAllocatorContext, lzwAllocSize);
    // handle.tlbMem = (u8 *) MSF_GIF_MALLOC(handle.customAllocatorContext, tlbAllocSize);
    // handle.usedMem = (u8 *) MSF_GIF_MALLOC(handle.customAllocatorContext, usedAllocSize);
    // handle.previousFrame.pixels = (u32 *) MSF_GIF_MALLOC(handle.customAllocatorContext, handle.width * handle.height * size_of(u32));
    // handle.currentFrame.pixels = (u32 *) MSF_GIF_MALLOC(handle.customAllocatorContext, handle.width * handle.height * size_of(u32));
    handle.previousFrame.pixels = cast(*u32) alloc(handle.width * handle.height * size_of(u32));
    handle.lzwMem               = cast(*s16) alloc(lzwAllocSize);
    handle.tlbMem               = cast(*u8)  alloc(tlbAllocSize);
    handle.usedMem              = cast(*u8)  alloc(usedAllocSize);
    handle.currentFrame.pixels  = cast(*u32) alloc(handle.width * handle.height * size_of(u32));


    //setup header buffer header (lol)
    handle.listHead = cast(*MsfGifBuffer) alloc(#run offset_of(MsfGifBuffer, "data") + 32);
    if !handle.listHead || !handle.lzwMem || !handle.previousFrame.pixels || !handle.currentFrame.pixels {
        msf_free_gif_state(handle);
        return 0;
    }
    handle.listTail = handle.listHead;
    handle.listHead.next = null;
    handle.listHead.size = 32;
    // headerBytes := "";
    //NOTE: because __attribute__((__packed__)) is annoyingly compiler-specific, we do this unreadable weirdness
    headerBytes := sprint("GIF89a\0\0\0\0\x70\0\0\x21\xFF\x0BNETSCAPE2.0\x03\x01\0\0\0");
    assert(headerBytes.count == 32, "count is %", headerBytes.count);
    //@Check the below lines are ok
    headerBytes[6] = cast(u8)(width & 0xFF);
    headerBytes[7] = cast(u8)((width >> 8) & 0xFF);
    headerBytes[8] = cast(u8)(height & 0xFF);
    headerBytes[9] = cast(u8)((height >> 8) & 0xFF);

    // memcpy(*headerBytes[6], width, 2);
    // memcpy(*headerBytes[8], height, 2);
    memcpy(*handle.listHead.data[0], headerBytes.data, 32);
    return 1;
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/// Frame Cooking                                                                                                    ///
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// #if (defined (__SSE2__) || defined (_M_X64) || _M_IX86_FP == 2) && !defined(MSF_GIF_NO_SSE2)
// #include <emmintrin.h>
// #endif

//The gif format only supports 1-bit transparency, meaning a pixel will either be fully transparent or fully opaque.
//Pixels with an alpha value less than the alpha threshold will be treated as transparent.
//To enable exporting transparent gifs, set it to a value between 1 and 255 (inclusive) before calling msf_gif_frame().
//Setting it to 0 causes the alpha channel to be ignored. Its initial value is 0.
msf_gif_alpha_threshold := 0;

//Set `msf_gif_bgra_flag = true` before calling `msf_gif_frame()` if your pixels are in BGRA byte order instead of RBGA.
msf_gif_bgra_flag := 0;

 msf_cook_frame :: (frame: *MsfCookedFrame, raw: *u8, used: *u8,
                           width: int, height: int, pitch: int, depth: int)
{
    log("cooking frame: width: %, height: %, pitch: %, depth: %", width, height, pitch, depth);
    //for profiling ->  MsfTimeFunc
    //bit depth for each channel
    rdepthsArray: [17]int = int.[ 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5 ];
    gdepthsArray: [17]int = int.[ 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6 ];
    bdepthsArray: [17]int = int.[ 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5 ];
    //this extra level of indirection looks unnecessary but we need to explicitly decay the arrays to pointers
    //in order to be able to swap them because of C's annoying not-quite-pointers, not-quite-value-types stack arrays.
    rdepths := ifx msf_gif_bgra_flag then bdepthsArray.data else rdepthsArray.data;
    gdepths := gdepthsArray.data;
    bdepths := ifx msf_gif_bgra_flag then rdepthsArray.data else bdepthsArray.data;


    ditherKernel: [16]s32 = s32.[
         0 << 12,  8 << 12,  2 << 12, 10 << 12,
        12 << 12,  4 << 12, 14 << 12,  6 << 12,
         3 << 12, 11 << 12,  1 << 12,  9 << 12,
        15 << 12,  7 << 12, 13 << 12,  5 << 12,
    ];


    cooked :*u32= frame.pixels;
    count := 0;
    // MsfTimeLoop("do") do
    while true
    {

    //@Check -> while (count >= 256 && --depth);

        rbits:int = rdepths[depth];
        gbits:int  = gdepths[depth];
        bbits:int  = bdepths[depth];
        paletteSize:int = (1 << (rbits + gbits + bbits)) + 1;
        memset(used, 0, paletteSize * size_of(u8));

        //TODO: document what this math does and why it's correct
        //(jai author): Do not do it, its obvious.
        rdiff:int = (1 << (8 - rbits)) - 1;
        gdiff:int = (1 << (8 - gbits)) - 1;
        bdiff:int = (1 << (8 - bbits)) - 1;
        rmul := cast(u16) ((255.0 - rdiff) / 255.0 * 257); //@Investigate(roufrouf): short is used as s16 here
        gmul := cast(u16) ((255.0 - gdiff) / 255.0 * 257); //@Investigate(roufrouf): short is used as s16 here
        bmul := cast(u16) ((255.0 - bdiff) / 255.0 * 257); //@Investigate(roufrouf): short is used as s16 here

        gmask:int = ((1 << gbits) - 1) << rbits;
        bmask:int = ((1 << bbits) - 1) << rbits << gbits;

        // MsfTimeLoop("cook")
        for y: 0 .. height - 1 {
            x :s32= 0;

            #if 1{

            k := *ditherKernel[(y & 3) * 4];
            // #asm AVX {
            //     movdqu.y loaded_in_reg:, [k];
            //     movdqu.y ssec:, [ssec_ptr];
            // }
            // Translation of SSE2 intrinsics to Jai #asm blocks
            // Original intrinsics -> Assembly mnemonics mapping:
            //
            // _mm_loadu_si128     -> movdqu (unaligned 128-bit load)
            // _mm_or_si128        -> por (bitwise OR of packed integers)
            // _mm_srli_epi32      -> psrld (shift right logical doublewords)
            // _mm_slli_epi32      -> pslld (shift left logical doublewords)
            // _mm_and_si128       -> pand (bitwise AND)
            // _mm_set1_epi32      -> broadcast or movd + pshufd
            // _mm_set_epi16       -> manual setup with movd/pinsrw or memory load
            // _mm_mullo_epi16     -> pmullw (multiply low words)
            // _mm_adds_epu16      -> paddusw (add with unsigned saturation)
            // _mm_cmplt_epi32     -> pcmpgtd with operands swapped (for less than)
            // _mm_andnot_si128    -> pandn (bitwise AND-NOT)
            // _mm_storeu_si128    -> movdqu (unaligned 128-bit store)

            ColorQuantizeSSE2 :: (raw: *u8, cooked: *u32, width: s32, height: s32, pitch: s32,
                                  rmul: u16, gmul: u16, bmul: u16,
                                  rbits: *u32, gbits: *u32, bbits: *u32,
                                   gmask: u32, bmask: u32,
                                  palette_minus_one: *u32, msf_gif_alpha_threshold: u32,
                                  ditherKernel: *s32) -> s32
            {
                assert(raw!=null);
                assert(cooked!=null);
                assert(ditherKernel!=null);
                y := 0; // Assuming we're processing one row, adjust as needed
                x :s32= 0;

                // Setup constants in memory (these could be global constants)
                mask_00FF00FF := u32.[0x00FF00FF, 0x00FF00FF, 0x00FF00FF, 0x00FF00FF].data;
                mask_000000FF := u32.[0x000000FF, 0x000000FF, 0x000000FF, 0x000000FF].data;
                mask_0000FFFF := u32.[0x0000FFFF, 0x0000FFFF, 0x0000FFFF, 0x0000FFFF].data;

                // Pack multipliers for SIMD
                mul_rb := u16.[rmul, bmul, rmul, bmul, rmul, bmul, rmul, bmul].data;
                mul_g  := u32.[gmul, gmul, gmul, gmul].data;

                bmask_vec := u32.[bmask, bmask, bmask, bmask].data;
                gmask_vec := u32.[gmask, gmask, gmask, gmask].data;


                alpha_threshold := u32.[msf_gif_alpha_threshold, msf_gif_alpha_threshold, msf_gif_alpha_threshold, msf_gif_alpha_threshold].data;

                #asm SSE2
                {
                    // Load dither kernel for current row: k = ditherKernel[(y & 3) * 4]
                    // mov y:, y;
                    and y, 3;              // y & 3
                    shl y, 4;              // * 16 bytes (4 ints * 4 bytes)
                    movdqu.x xmm0:, [ditherKernel + y];  // k = _mm_loadu_si128

                    // Prepare k2 = (k >> rbits) | ((k >> bbits) << 16)
                    movdqa.x k2:, xmm0;
                    movdqa.x tmp:, xmm0;
                    psrld.x k2, [rbits];       // k >> rbits
                    psrld.x tmp, [bbits];     // k >> bbits
                    pslld.x tmp, 16;        // << 16
                    por.x k2, tmp;          // OR them together
                }

                while x < width - 3
                {
                    pixels_ptr := raw + (y * pitch + x * 4);
                    cooked_ptr := cooked + (y * width + x);

                    #asm AVX
                    {
                        // Load 4 pixels (RGBA, 4 bytes each = 16 bytes total)
                        movdqu.x p:, [pixels_ptr];  // p = _mm_loadu_si128

                        // Extract red and blue channels: rb = p & 0x00FF00FF
                        movdqa.x rb:, p;
                        pand.x rb, [mask_00FF00FF];
                    // }
                    //     #asm AVX
                    // {
                        // Multiply red and blue by their multipliers
                        // rb1 = rb * [rmul, bmul, rmul, bmul, ...]
                        pmullw.x rb1:, rb, [mul_rb];  // _mm_mullo_epi16
                         // Add dither with saturation: rb2 = rb1 + k2
                        paddusw.x rb2:, rb1, k2;  // _mm_adds_epu16

                    // }
                    //    #asm SSE2
                    // {

                        // Extract final red values
                        // r3 = (rb2 & 0x0000FFFF) >> (16 - rbits)
                        movdqa.x r3:, rb2;
                        pand.x r3, [mask_0000FFFF];
                        mov ecx:, 16;
                        sub ecx, [rbits];
                        movd xmm0, ecx;
                        psrld.x r3, xmm0;//ecx

                        // Extract final blue values
                        // b3 = (rb2 >> (32 - rbits - gbits - bbits)) & bmask
                        movdqa.x b3:, rb2;
                        mov ecx, 32;
                        sub ecx, [rbits];
                        sub ecx, [gbits];
                        sub ecx, [bbits];
                        movd xmm0, ecx;
                        psrld.x b3, xmm0;//ecx

                        pand.x b3, [bmask_vec];

                        // Extract and process green channel
                        // g = (p >> 8) & 0x000000FF
                        movdqa.x g:, p;
                        psrld.x g, 8;
                        pand.x g, [mask_000000FF];
                   //  }
                   //       #asm AVX
                   //  {
                        // g1 = g * gmul
                        pmullw.x g1:, g, [mul_g];  // Note: might need pmulld for 32-bit
                   //  }
                   //   #asm SSE2
                   //  {
                        // g2 = g1 + (k >> gbits)
                        movdqa.x k_shifted:, xmm0;
                        psrld.x k_shifted, [gbits]; //gbits
                   //  }
                   //   #asm AVX
                   //  {
                        paddusw.x g2:, g1, k_shifted;
                   //  }
                   //  #asm SSE2
                   //  {
                        // g3 = (g2 >> (16 - rbits - gbits)) & gmask
                        movdqa.x g3:, g2;
                        mov ecx, 16;
                        sub ecx, rbits;
                        sub ecx, gbits;
                        movd xmm0, ecx;
                        psrld.x g3, xmm0; //ecx
                        pand.x g3, [gmask_vec];
                   //  }
                   //     #asm AVX
                   //  {
                        // Combine channels: out = r3 | g3 | b3
                        por.x out:, r3, g3;
                        por.x out, b3;
                   //  }
                   //     #asm SSE2
                   //  {
                        // Alpha threshold check
                        // invAlphaMask = (p >> 24) < alpha_threshold
                        movdqa.x alpha:, p;
                        psrld.x alpha, 24;

                        // For signed comparison of unsigned values, we need to flip sign bit
                        // or use a different approach. Here we'll use pcmpgtd backwards
                        movdqa.x threshold:, [alpha_threshold];

                   //  }   #asm AVX
                   //  {//invAlphaMask xmm1
                        pcmpgtd.x xmm1:, threshold, alpha;  // threshold > alpha
                   //  }
                   //  #asm SSE2
                   //  {
                        // Conditional select based on alpha
                        // out = (invAlphaMask & (paletteSize-1)) | (~invAlphaMask & out)

                        // movdqa.x xmm0, [palette_minus_one]; //xmm0 is palette_val
                        pand.x xmm0, xmm1;
                        pandn.x xmm1, out;  // ~invAlphaMask & out

                   //      }
                   // #asm AVX
                   //  {
                        por.x out, xmm0, xmm1;
                   //  }
                   //   #asm SSE2
                   //  {
                        // Store result
                        movdqu.x [cooked_ptr], out;  // _mm_storeu_si128
                    }

                    x += 4;
                }

                return x;
                // Handle remaining pixels with scalar code
                // ...
            }
            palette_minus_one := u32.[paletteSize.(u32) - 1, paletteSize.(u32) - 1, paletteSize.(u32) - 1, paletteSize.(u32) - 1].data;
            // x = ColorQuantizeSSE2(raw, cooked,cast(s32) width, cast(s32)height, cast(s32)pitch,
            //                       rmul, gmul, bmul,
            //                       cast(*u32)*rbits, cast(*u32)*gbits, cast(*u32)*bbits,
            //                       cast(u32)gmask, cast(u32)bmask,
            //                       palette_minus_one, cast(u32)msf_gif_alpha_threshold,
            //                         ditherKernel.data);

            // _mm_loadu_si128     -> movdqu (unaligned 128-bit load)
            // _mm_or_si128        -> por (bitwise OR of packed integers)
            // _mm_srli_epi32      -> psrld (shift right logical doublewords)
            // _mm_slli_epi32      -> pslld (shift left logical doublewords)
            // _mm_and_si128       -> pand (bitwise AND)
            // _mm_set1_epi32      -> broadcast or movd + pshufd
            // _mm_set_epi16       -> manual setup with movd/pinsrw or memory load
            // _mm_mullo_epi16     -> pmullw (multiply low words)
            // _mm_adds_epu16      -> paddusw (add with unsigned saturation)
            // _mm_cmplt_epi32     -> pcmpgtd with operands swapped (for less than)
            // _mm_andnot_si128    -> pandn (bitwise AND-NOT)
            // _mm_storeu_si128    -> movdqu (unaligned 128-bit store)
            dither_kernel_ptr := *ditherKernel[(y & 3) * 4];
            #asm AVX {
                movdqu.x xmm0:, [dither_kernel_ptr]; //k
                movd xmm1:, rbits; //a1 prepare
                movdqa.x xmm2:, xmm0; //k copy into xmm2 dont override k because we will use it agai below
                psrld.x xmm2, xmm1; //a1: k >> rbits
                //xmm1 is free, xmm2 is a1
                movd xmm1, bbits; //a2 prepare
                movdqa.x xmm3:, xmm0; //copy of k
                pslld.x xmm3, xmm1; //a2: k << bbits; LEFT!
                //xmm1 is free, xmm3 is a2

                //we use a2 and 16 to generate a3, a3 will be replace the space of memory of a2 because we dont need a2 anymore
                //we use a2(xmm3) itself to store a3
                psrld.x xmm3, 16; //  a2 >> 16;
                //xmm3 is a3 now
                por.x xmm2, xmm3; //a1 OR a3


                //we will never replace xmm0 and xmm2 from now on
                //xmm0 is k, xmm2 is k2, xmm1 is free xmm3 is free
            };

            mask_00FF00FF := u32.[0x00FF00FF, 0x00FF00FF, 0x00FF00FF, 0x00FF00FF].data;
            mask_0000FFFF := u32.[0x0000FFFF, 0x0000FFFF, 0x0000FFFF, 0x0000FFFF].data;
            mask_000000FF := u32.[0x000000FF, 0x000000FF, 0x000000FF, 0x000000FF].data;

            mul_rb := u16.[rmul, bmul, rmul, bmul, rmul, bmul, rmul, bmul].data;
            mul_g  := u32.[gmul, gmul, gmul, gmul].data;

            bmask_vec := u32.[cast(u32)bmask, cast(u32)bmask, cast(u32)bmask, cast(u32)bmask].data;
            gmask_vec := u32.[cast(u32)gmask, cast(u32)gmask, cast(u32)gmask, cast(u32)gmask].data;

            alpha_threshold := u32.[cast(u32)msf_gif_alpha_threshold, cast(u32)msf_gif_alpha_threshold,cast(u32) msf_gif_alpha_threshold, cast(u32)msf_gif_alpha_threshold].data;

            while x < width - 3 { defer x+=4;
                 pixels_ptr := *raw[y * pitch + x * 4];
                 #asm AVX {
                    movdqu.x xmm3, [pixels_ptr]; //xmm3 is p, xmm3 is fixed for the whole #asm block.
                    //maskara: _mm_set1_epi32(0x00FF00FF); we do this out of #asm
                    pand.x xmm4:, [mask_00FF00FF]; //xmm4 is rb
                    //111111111111111111111111111111
                    pmullw.x xmm5:, xmm4, [mul_rb];  // xmm5 is rb1
                    //xmm4 is free now
                    paddusw.x xmm4, xmm5, xmm2;  // xmm2 is k2, xmm4 is rb2 now
                    //xmm5 is free now
                    pand.x xmm5, [mask_0000FFFF]; //xmm5 is rb3
                    //22222222222222222222222222222

                    //I indent this because idk
                        mov ecx:, 16;
                        sub ecx, rbits;
                        movd xmm6:, ecx;
                    //xmm6 is loaded with (16 - rbits)

                    psrld.x xmm5, xmm6; //xmm5 is r3: is rb3 shifyed by  (16 - rbits)
                    //xmm5 WILL be used near the end after //7777 , so we are stuck with it and cant reuse it.
                    //xmm6 is free now

                    //I indent this because idk
                        mov ecx, 32; //we reuse ecx
                        sub ecx, rbits;
                        sub ecx, gbits;
                        sub ecx, bbits;
                        movd xmm6, ecx;  //xmm6 is 32 - rbits - gbits - bbits
                    //finally we can use xmm4 that is rb2
                    psrld.x xmm4, xmm6; // shift right (rb2, 32 - rbits - gbits - bbits)
                    //xmm6 is free now
                    //xmm4 is somsom
                    pand.x xmm4, [bmask_vec]; //xmm4 is b3 now
                    //we use b3 at the end D:
                    //so far we are stuck with xmm3 xmm4 xmm5 (xmm0 xmm2 xmm2 from outside the while loop)
                    //333333333333333333333333333
                    movdqa.x xmm6, xmm3; //we copy xmm3 that is the pixel
                    psrld.x xmm6, 8; // >> 8
                    pand.x xmm6, [mask_000000FF]; //xmm6 is g
                    //444444444444444444444444444
                    pmullw.x xmm6, [mul_g]; // xmm6 is g1 now
                    //5555555555555555
                    //we finnaly use k again from outsid ethe while loop, xmm0 is k
                    movdqa.x xmm7:, xmm0; //we copy k into xmm7

                    //I indent this because idk
                        mov ecx, gbits; //we reuse ecx
                        movd xmm1, ecx;  //xmm1 is gbits

                    psrld.x xmm7, xmm1; //>>gbits
                    paddusw.x xmm6, xmm7; //we add to g1 the shifted k xmm7, we reuse g1 tho.
                    //xmm7 is free now
                    //xmm6 is g2 now
                    //666666666666666
                    //I indent this because idk
                        // movdqa.x xmm7, xmm6; //we copy g2 into xmm7
                        mov ecx, 16; //we reuse ecx
                        sub ecx, rbits;
                        sub ecx, gbits;
                        movd xmm7, ecx; //( 16 - rbits - gbits)
                        psrld.x xmm6, xmm7; //we reuse xmm6 that is g2, and we shift it too
                    //emm idk what to comment anymore  (ecx is xmm7 but is free now )
                    //xmm7 is free now
                    //xmm6 is mule now
                    pand.x xmm6, [gmask_vec]; //AND (mule, mask_vec)
                    //xmm6 is g3 now
                    //7777777777777777
                    //finally we use r3(xmm5) and b3(xmm4)
                    //recap, xmm0 is k, xmm2 is k2, xmm1 is... oh wait, xmm1 is free I think, not anymore, I used it. well its free anyways
                    //xmm3 is the pixel, xmm4 is b3 xmm5 is r3 xmm6 is g3
                    //ahh, is this normal programming?
                    por.x xmm5, xmm6; //r3 OR g3
                    //xmm5 is ohoh, xmm6 is free, xmm1 is free
                    por.x xmm5, xmm4;
                    //xmm5 is OUT, xmm4 is free now
                    //mask in transparency based on threshold
                    //NOTE: nop
                    movdqa.x xmm1, xmm3; //we copy the pixel, just in case.
                    psrld.x xmm1, 24;
                    movdqa.x xmm6, [alpha_threshold]; //xmm6 is now alha treshold
                    pcmpgtd.x xmm1, xmm6;  // threshold > alpha
                    //xmm6 is free
                    //88888888888888888888888888

                    // pand.x xmm0, xmm1;
                    // pandn.x xmm1, out;  // ~invAlphaMask & out
                    // por.x out, xmm0, xmm1;

                 }
                 cooked_ptr :*u32= *cooked[y * width + x];;
                 #asm AVX{

                    movdqu.x [cooked_ptr], xmm5;  // _mm_storeu_si128
                 }
                 x+=4;//by 4? can I do by 8?
            }
cppversion :: #string CPP
               __m128i k = _mm_loadu_si128((__m128i *) &ditherKernel[(y & 3) * 4]);
                a1: := _mm_srli_epi32(k, rbits);
                a2: := _mm_srli_epi32(k, bbits);
                a3: := _mm_slli_epi32(a2, 16);
                __m128i k2 = _mm_or_si128(a1, a3);

                // for (; x < width - 3; x += 4) {
                while x < width - 3 { defer x+=4;
                    u8 * pixels = &raw[y * pitch + x * 4];
                    __m128i p = _mm_loadu_si128((__m128i *) pixels);
                    maskara: _mm_set1_epi32(0x00FF00FF);
                    __m128i rb = _mm_and_si128(p, maskara);
                    //111111111111111111111111111111
                    mule := _mm_set_epi16(bmul, rmul, bmul, rmul, bmul, rmul, bmul, rmul)
                    __m128i rb1 = _mm_mullo_epi16(rb, mule);
                    __m128i rb2 = _mm_adds_epu16(rb1, k2);
                    maskara = _mm_set1_epi32(0x0000FFFF);
                    rb3 = _mm_and_si128(rb2, maskara)
                    //22222222222222222222222222222
                    __m128i r3 = _mm_srli_epi32(rb3, 16 - rbits);
                    somsom := _mm_srli_epi32(rb2, 32 - rbits - gbits - bbits);
                    ssasa := _mm_set1_epi32(bmask);
                    __m128i b3 = _mm_and_si128(somsom, ssasa);
                    //333333333333333333333333333
                    maskara = _mm_set1_epi32(0x000000FF);
                    rere := _mm_srli_epi32(p, 8);
                    __m128i g = _mm_and_si128(rere, maskara);
                    //444444444444444444444444444
                    mule = _mm_set1_epi32(gmul);
                    __m128i g1 = _mm_mullo_epi16(g, mule);
                    //55555555555
                    mule1 = _mm_srli_epi32(k, gbits);
                    __m128i g2 = _mm_adds_epu16(g1, mule1 );
                    //666666666666666
                    mule = _mm_srli_epi32(g2, 16 - rbits - gbits)
                    maskara = _mm_set1_epi32(gmask)
                    __m128i g3 = _mm_and_si128(mule, maskara);
                    //7777777777777777
                    ohoh :=   _mm_or_si128(r3, g3)
                    __m128i out = _mm_or_si128(ohoh, b3);

                    //mask in transparency based on threshold
                    //NOTE: we can theoretically do a sub instead of srli by doing an unsigned compare via bias
                    //      to maybe save a TINY amount of throughput? but lol who cares maybe I'll do it later -m
                    almost := _mm_srli_epi32(p, 24);
                    done := _mm_set1_epi32(msf_gif_alpha_threshold);
                    __m128i invAlphaMask = _mm_cmplt_epi32(almost, done);
                    //88888888888888888888888888
                    done := _mm_set1_epi32(paletteSize - 1);
                    somsom := _mm_and_si128(invAlphaMask, done))
                    sasa := _mm_andnot_si128(invAlphaMask, out);

                    out = _mm_or_si128(somsom, sasa);

                    //TODO: does storing this as a __m128i then reading it back as a u32 violate strict aliasing?
                    u32 * c = &cooked[y * width + x];
                    _mm_storeu_si128((__m128i *) c, out);

                    }
CPP

            //TODO(roufrouf): make this simd in #asm blocks
            // #if (defined (__SSE2__) || defined (_M_X64) || _M_IX86_FP == 2) && !defined(MSF_GIF_NO_SSE2)
            //     __m128i k = _mm_loadu_si128((__m128i *) &ditherKernel[(y & 3) * 4]);
            //     __m128i k2 = _mm_or_si128(_mm_srli_epi32(k, rbits), _mm_slli_epi32(_mm_srli_epi32(k, bbits), 16));
            //     for (; x < width - 3; x += 4) {
            //         u8 * pixels = &raw[y * pitch + x * 4];
            //         __m128i p = _mm_loadu_si128((__m128i *) pixels);

            //         __m128i rb = _mm_and_si128(p, _mm_set1_epi32(0x00FF00FF));
            //         __m128i rb1 = _mm_mullo_epi16(rb, _mm_set_epi16(bmul, rmul, bmul, rmul, bmul, rmul, bmul, rmul));
            //         __m128i rb2 = _mm_adds_epu16(rb1, k2);
            //         __m128i r3 = _mm_srli_epi32(_mm_and_si128(rb2, _mm_set1_epi32(0x0000FFFF)), 16 - rbits);
            //         __m128i b3 = _mm_and_si128(_mm_srli_epi32(rb2, 32 - rbits - gbits - bbits), _mm_set1_epi32(bmask));

            //         __m128i g = _mm_and_si128(_mm_srli_epi32(p, 8), _mm_set1_epi32(0x000000FF));
            //         __m128i g1 = _mm_mullo_epi16(g, _mm_set1_epi32(gmul));
            //         __m128i g2 = _mm_adds_epu16(g1, _mm_srli_epi32(k, gbits));
            //         __m128i g3 = _mm_and_si128(_mm_srli_epi32(g2, 16 - rbits - gbits), _mm_set1_epi32(gmask));

            //         __m128i out = _mm_or_si128(_mm_or_si128(r3, g3), b3);

            //         //mask in transparency based on threshold
            //         //NOTE: we can theoretically do a sub instead of srli by doing an unsigned compare via bias
            //         //      to maybe save a TINY amount of throughput? but lol who cares maybe I'll do it later -m
            //         __m128i invAlphaMask = _mm_cmplt_epi32(_mm_srli_epi32(p, 24), _mm_set1_epi32(msf_gif_alpha_threshold));
            //         out = _mm_or_si128(_mm_and_si128(invAlphaMask, _mm_set1_epi32(paletteSize - 1)), _mm_andnot_si128(invAlphaMask, out));

            //         //TODO: does storing this as a __m128i then reading it back as a u32 violate strict aliasing?
            //         u32 * c = &cooked[y * width + x];
            //         _mm_storeu_si128((__m128i *) c, out);
            //     }
            // #endif
            }
            else
            {

                /* scalar fallback replacing the SSE block (inside y loop) */

                // for (; x < width - 3; x += 4) {
                    // for (int i = 0; i < 4; ++i) {
                ax:=0;
                while ax<width-3 {
                defer ax += 4;

                    i:= 0;
                    while i<4 {
                    defer i += 1;

                        pixels :*u8= *raw[y * pitch + (x + i) * 4];

                        /* transparency */
                        if (pixels[3] < msf_gif_alpha_threshold) {
                            cooked[y * width + x + i] =cast(u32) paletteSize - 1;
                            continue;
                        }

                        dx: int = (x + i) & 3;
                        k: int = ditherKernel[(y & 3) * 4 + dx];

                        /* use same math as scalar cleanup (keep min semantics) */
                        part_b:int = ( min(65535, pixels[2] * bmul + (k >> bbits))
                                       >> (16 - rbits - gbits - bbits) ) & bmask;
                        part_g:int = ( min(65535, pixels[1] * gmul + (k >> gbits))
                                       >> (16 - rbits - gbits) ) & gmask;
                        part_r:int =   min(65535, pixels[0] * rmul + (k >> rbits))
                                       >> (16 - rbits);

                        cooked[y * width + x + i] = cast(u32)(part_b | part_g | part_r);
                    }
                }


            }
            //scalar cleanup loop
            assert(paletteSize >= 0);
            curr_iters := 0;
            MAX_ITERS :: 2048;
            while x<width {
            defer x += 1;
            defer curr_iters += 1;
            assert(curr_iters < MAX_ITERS,"MAX_ITERS %, width%", x,  width);
                //uint8_t * p = &raw[y * pitch + x * 4];
                 p : *u8= *raw[y * pitch + x * 4];

                //transparent pixel if alpha is low
                if (p[3] < msf_gif_alpha_threshold) {
                    cooked[y * width + x] = cast(u32) (paletteSize - 1);
                    continue;
                }

                dx:int = x & 3;
                dy:int = y & 3;
                k:int = ditherKernel[dy * 4 + dx];


                a := (( min(65535, p[2] * bmul + (k >> bbits)) >> (16 - rbits - gbits - bbits))  & bmask );
                b := (( min(65535, p[1] * gmul + (k >> gbits)) >> (16 - rbits - gbits        ))  & gmask );
                c := (( min(65535, p[0] * rmul + (k >> rbits)) >> (16 - rbits                ))          );
                cooked[y * width + x] =cast,trunc(u32) (a | b | c);

            }

        }

        count = 0;
        // MsfTimeLoop("mark")
        for i: 0 .. width * height - 1 {
            used[cooked[i]] = 1;
        }

        //count used colors, transparent is ignored
        // MsfTimeLoop("count")
        // for (int j = 0; j < paletteSize - 1; ++j) {
        for j: 0 .. paletteSize - 2 {
            count += used[j];
        }

    if count >= 256 {
        depth -= 1;
        if !depth then break;

    }else break;
    }

    result := MsfCookedFrame.{ cooked, depth, count, rdepths[depth], gdepths[depth], bdepths[depth] };
    frame.* = result;
}



////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/// Frame Compression                                                                                                ///
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////




 msf_put_code :: (writeHead: **u8, blockBits: *u32, len: int, code: u32) {
    assert(writeHead != null);
    assert(writeHead.* != null);

    //insert new code into block buffer
    idx:int =(( blockBits.*) / 8);
    bit:int =(( blockBits.*) % 8);
    // if bit != 0
    // then bit = 3;
    (writeHead.*)[idx + 0] |= cast,no_check(u8)( code <<       bit ); //ERROR  Cast bounds check failed.  Number must be in [0, 255]; it was 472.
    (writeHead.*)[idx + 1] |= cast,no_check(u8)( code >> ( 8 - bit));
    (writeHead.*)[idx + 2] |= cast,no_check(u8)( code >> (16 - bit));
    blockBits.* +=xx len;

    //prep the next block buffer if the current one is full
    if (blockBits.* >= 256 * 8) {
        blockBits.* -= 255 * 8;
        (writeHead.*) += 256;
        (writeHead.*)[2] = (writeHead.*)[1];
        (writeHead.*)[1] = (writeHead.*)[0];
        (writeHead.*)[0] = 255;
        memset((writeHead.*) + 4, 0, 256);
    }
}

MsfStridedList :: struct {
    data: *s16;
    len: int;
    stride: int;
};

msf_lzw_reset :: inline (lzw: *MsfStridedList, tableSize: int, stride: int) {
//ppprooofff -> MsfTimeFunc
    memset(lzw.data, 0xFF, 4096 * stride * size_of(s16));
    lzw.len = tableSize + 2;
    lzw.stride = stride;
}

//PERF TODO: is it possible to use the same array for both `used` and `tlb`?
 msf_compress_frame :: (/*jai has context already -> void * allocContext, */
                        width: int, height: int, centiSeconds: int,
                        frame: MsfCookedFrame, handle: *MsfGifState, used: *u8, tlb: *u8, lzwMem: *s16) -> *MsfGifBuffer
{
//pro fi ling -> MsfTimeFunc
    //NOTE: We reserve enough memory for the theoretical worst case upfront because it's a reasonable amount,
    //      and prevents us from ever having to check size or realloc during compression.
    //NOTE: headers + color table + 12 bits per pixel (since 12 bits is the maximum code size)
    //      + space for at least one full Image Data block (needed for small images since we zero a whole block at a time)
    maxBufSize:int = offset_of(MsfGifBuffer, "data") + 32 + 256 * 3 + width * height * 3 / 2 + (256 + 4);

    buffer := cast(*MsfGifBuffer) alloc(maxBufSize);
    if !buffer return null;
    writeHead: *u8 = *buffer.data[0];
    lzw := MsfStridedList.{ lzwMem,0,0 };

    //allocate tlb
    totalBits:int = frame.rbits + frame.gbits + frame.bbits;
    tlbSize:int = (1 << totalBits) + 1;
    //generate palette
    Color3 :: struct {
        r:u8;
        g:u8;
        b:u8;
     };

    table: [256]Color3;
    tableIdx:int = 1; //we start counting at 1 because 0 is the transparent color
    //transparent is always last in the table
    tlb[tlbSize-1] = 0;
    // MsfTimeLoop("table")
    // for (int i = 0; i < tlbSize-1; ++i) {
    for i: 0..tlbSize-2 {
        if (used[i]) {
            tlb[i] =cast(u8) tableIdx;
            rmask:int = (1 << frame.rbits) - 1;
            gmask:int = (1 << frame.gbits) - 1;
            //isolate components
            r:int = i & rmask;
            g:int = i >> frame.rbits & gmask;
            b:int = i >> (frame.rbits + frame.gbits);

            //shift into highest bits
            r <<= 8 - frame.rbits;
            g <<= 8 - frame.gbits;
            b <<= 8 - frame.bbits;
            table[tableIdx].r =cast(u8)(( r )|( r >> frame.rbits )|( r >> (frame.rbits * 2) )|( r >> (frame.rbits * 3)));
            table[tableIdx].g =cast(u8)(( g )|( g >> frame.gbits )|( g >> (frame.gbits * 2) )|( g >> (frame.gbits * 3)));
            table[tableIdx].b =cast(u8)(( b )|( b >> frame.bbits )|( b >> (frame.bbits * 2) )|( b >> (frame.bbits * 3)));
            if (msf_gif_bgra_flag) {
                tmp := table[tableIdx].r;
                table[tableIdx].r = table[tableIdx].b;
                table[tableIdx].b = tmp;
            }
            tableIdx += 1;
        }
    }
    hasTransparentPixels:int = used[tlbSize-1];

    //SPEC: "Because of some algorithmic constraints however, black & white images which have one color bit
    //       must be indicated as having a code size of 2."
    // log("aa %", msf_bit_log(tableIdx - 1));
    // log("hasTransparentPixels %", used[tlbSize-1]);
    // log("hasTransparentPixels %", used[tlbSize-2]);
    // log("hasTransparentPixels %", used[tlbSize-3]);
    tableBits:int = max(2, msf_bit_log(tableIdx - 1));
    // log("tableIdx %", tableIdx);
    // log("tableBits %", tableBits);
    tableSize:int = 1 << tableBits;
    // log("tableSize %", tableSize);
    //NOTE: we don't just compare `depth` field here because it will be wrong for the first frame and we will segfault
    previous: MsfCookedFrame = handle.previousFrame;
    hasSamePal:int = cast(int) (frame.rbits == previous.rbits && frame.gbits == previous.gbits && frame.bbits == previous.bbits);
    // hasSamePal:int = frame.rbits == previous.rbits && frame.gbits == previous.gbits && frame.bbits == previous.bbits;
    framesCompatible:int = cast(int)( hasSamePal && !hasTransparentPixels);
    // framesCompatible:int = hasSamePal && !hasTransparentPixels;

    //write the Graphics `Control Extension` and `Image Descriptor` blocks
    //NOTE: because __attribute__((__packed__)) is annoyingly compiler-specific, we do this unreadable weirdness
    // char headerBytes[19] = "\x21\xF9\x04\x05\0\0\0\0" "\x2C\0\0\0\0\0\0\0\0\x80";
    headerBytes := sprint("\x21\xF9\x04\x05\0\0\0\0\x2C\0\0\0\0\0\0\0\0\x80");
    assert(headerBytes.count == 18, "headerBytes 19 %",headerBytes.count);
    //NOTE: we need to check the frame number because if we reach into the buffer prior to the first frame,
    //      we'll just clobber the file header instead, which is a bug
    if (hasTransparentPixels && handle.framesSubmitted > 0) {
        (*handle.listTail.data[0])[3] = 0x09; //set the previous frame's disposal to background, so transparency is possible
    }

    memcpy(*headerBytes[4], *centiSeconds, 2);
    memcpy(*headerBytes[13], *width, 2);
    memcpy(*headerBytes[15], *height, 2);
    headerBytes[17] |=cast(u8) (tableBits - 1);
    memcpy(writeHead, headerBytes.data, 18);
    writeHead += 18;

    //write Local Color Table
    memcpy(writeHead, table.data, tableSize * size_of(Color3));
    writeHead += tableSize * size_of(Color3);
    // *writeHead++ = tableBits;
    writeHead.* =cast(u8) tableBits;
    writeHead += 1; //?? c weirdness

      //prep first Image Data block (analogous to what we do at the end of msf_put_code())
    memset(writeHead, 0, 256 + 4); //we write up to 4 bytes ahead of the end of the block - see msf_put_code()
    writeHead[0] = 255;
    blockBits:u32 = 8; //relative to block.head

    //SPEC: "Encoders should output a Clear code as the first code of each image data stream."
    msf_lzw_reset(*lzw, tableSize, tableIdx);
    msf_put_code(*writeHead, *blockBits, msf_bit_log(lzw.len - 1), cast(u32) tableSize);

    lastCode:int = ifx (framesCompatible && frame.pixels[0] ==  previous.pixels[0]) then 0 else tlb[frame.pixels[0]];
    // MsfTimeLoop("compress")
    // for (int i = 1; i < width * height; ++i) {
    for i : 1.. width * height - 1 {
        //PERF: branching vs. branchless version of this line is observed to have no discernable impact on speed
        color: int  = ifx (framesCompatible && frame.pixels[i] ==  previous.pixels[i]) then 0 else tlb[frame.pixels[i]];
        code: int  = (*lzw.data[lastCode * lzw.stride])[color];
        if (code < 0) {
            //write to code stream
            codeBits: int = msf_bit_log(lzw.len - 1);
            msf_put_code(*writeHead, *blockBits, codeBits, cast(u32)lastCode);

            if (lzw.len > 4095) {
                //reset buffer code table
                msf_put_code(*writeHead, *blockBits, codeBits, cast(u32)tableSize);
                msf_lzw_reset(*lzw, tableSize, tableIdx);
            } else {
                // (&lzw.data[lastCode * lzw.stride])[color] = lzw.len;
                (*lzw.data[lastCode * lzw.stride])[color] = cast(s16) lzw.len;
                lzw.len += 1;
            }

            lastCode = color;
        } else {
            lastCode = code;
        }
    }

    //write code for leftover index buffer contents, then the end code
    msf_put_code(*writeHead, *blockBits, min(12, msf_bit_log(lzw.len - 1)), cast(u32) lastCode);
    msf_put_code(*writeHead, *blockBits, min(12, msf_bit_log(lzw.len)), cast(u32) tableSize + 1);

    //flush remaining data
    if (blockBits > 8) {
        bytes: int = (blockBits + 7) / 8; //round up
        writeHead[0] = cast(u8) bytes - 1;
        writeHead += bytes;
    }
    // *writeHead++ = 0; //terminating block
    writeHead.* = 0; //terminating block
    writeHead += 1; //idk man

    //fill in buffer header and shrink buffer to fit data
    buffer.next = null;
    buffer.size = writeHead - buffer.data.data;
    moved := cast(*MsfGifBuffer) realloc(buffer, maxBufSize, offset_of(MsfGifBuffer, "data") + buffer.size);
         // MSF_GIF_REALLOC(allocContext, buffer, maxBufSize, offset_of(MsfGifBuffer, data) + buffer.size);

    if (!moved)
    {
        free(buffer);
        return null;
    }
    return moved;
}


codetoparse :: #string CPP
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/// HEADER                                                                                                           ///
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////



////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/// To-file API                                                                                                      ///
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


//TO-FILE FUNCTIONS
//These functions are equivalent to the ones above, but they write results to a file incrementally,
//instead of building a buffer in memory. This can result in lower memory usage when saving large gifs,
//because memory usage is bounded by only the size of a single frame, and is not dependent on the number of frames.
//There is currently no reason to use these unless you are on a memory-constrained platform.
//If in doubt about which API to use, for now you should use the normal (non-file) functions above.
//The signature of MsfGifFileWriteFunc matches fwrite for convenience, so that you can use the C file API like so:
//  FILE * fp = fopen("MyGif.gif", "wb");
//  msf_gif_begin_to_file(&handle, width, height, (MsfGifFileWriteFunc) fwrite, (void *) fp);
//  msf_gif_frame_to_file(...)
//  msf_gif_end_to_file(&handle);
//  fclose(fp);
//If you use a custom file write function, you must take care to return the same values that fwrite() would return.
//Note that all three functions will potentially write to the file.

int msf_gif_begin_to_file(MsfGifState * handle, int width, int height, MsfGifFileWriteFunc func, void * filePointer) {
    handle.fileWriteFunc = func;
    handle.fileWriteData = filePointer;
    return msf_gif_begin(handle, width, height);
}

int msf_gif_frame_to_file(MsfGifState * handle, u8 * pixelData, int centiSecondsPerFrame, int quality, int pitchInBytes) {
    if (!msf_gif_frame(handle, pixelData, centiSecondsPerFrame, quality, pitchInBytes)) { return 0; }

    //NOTE: this is a somewhat hacky implementation which is not perfectly efficient, but it's good enough for now
    MsfGifBuffer * head = handle.listHead;
    if (!handle.fileWriteFunc(head.data, head.size, 1, handle.fileWriteData)) { msf_free_gif_state(handle); return 0; }
    handle.listHead = head.next;
    MSF_GIF_FREE(handle.customAllocatorContext, head, offset_of(MsfGifBuffer, "data") + head.size);
    return 1;
}

int msf_gif_end_to_file(MsfGifState * handle) {
    //NOTE: this is a somewhat hacky implementation which is not perfectly efficient, but it's good enough for now
    MsfGifResult result = msf_gif_end(handle);
    int ret = (int) handle.fileWriteFunc(result.data, result.dataSize, 1, handle.fileWriteData);
    msf_gif_free(result);
    return ret;
}

#endif //MSF_GIF_ALREADY_IMPLEMENTED_IN_THIS_TRANSLATION_UNIT
#endif //MSF_GIF_IMPL
CPP



////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/// To-memory API                                                                                                    ///
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

 lzwAllocSize :: 4096 * 256 * size_of(s16);
 tlbAllocSize :: ((1 << 16) + 1) * size_of(u8);
 usedAllocSize :: ((1 << 16) + 1) * size_of(u8);

//NOTE: by C standard library conventions, freeing null should be a no-op,
//      but just in case the user's custom free doesn't follow that rule, we do null checks on our end as well.
msf_free_gif_state :: (handle: *MsfGifState) {
    if (handle.previousFrame.pixels) free(handle.previousFrame.pixels);
    if (handle.currentFrame.pixels)  free(handle.currentFrame.pixels);
    if (handle.lzwMem) free(handle.lzwMem);
    if (handle.tlbMem) free(handle.tlbMem);
    if (handle.usedMem) free(handle.usedMem);
    // if (handle.previousFrame.pixels) MSF_GIF_FREE(handle.customAllocatorContext, handle.previousFrame.pixels, handle.width * handle.height * size_of(u32));
    // if (handle.currentFrame.pixels)  MSF_GIF_FREE(handle.customAllocatorContext, handle.currentFrame.pixels, handle.width * handle.height * size_of(u32));
    // if (handle.lzwMem) MSF_GIF_FREE(handle.customAllocatorContext, handle.lzwMem, lzwAllocSize);
    // if (handle.tlbMem) MSF_GIF_FREE(handle.customAllocatorContext, handle.tlbMem, tlbAllocSize);
    // if (handle.usedMem) MSF_GIF_FREE(handle.customAllocatorContext, handle.usedMem, usedAllocSize);
    // for (MsfGifBuffer * node = handle.listHead; node;) {
    start: *MsfGifBuffer = handle.listHead;
    while start {
        next := start.next; //NOTE: we have to copy the `next` pointer BEFORE freeing the node holding it
        free(start);
        start = next;
    }
    handle.listHead = null; //this implicitly marks the handle as invalid until the next msf_gif_begin() call
}


msf_gif_frame :: (handle: *MsfGifState, pixelData: *u8, centiSecondsPerFrame: int, quality: int, pitchInBytes: int) -> int
{
    //-> profile -> MsfTimeFunc
    if !handle.listHead return 0;

    //TODO: sanity-check `pitchInBytes`

    quality = max(1, min(16, quality));
    if pitchInBytes == 0 then pitchInBytes = handle.width * 4;
    if pitchInBytes < 0 then pixelData -= pitchInBytes * (handle.height - 1);

    msf_cook_frame(*handle.currentFrame, pixelData, handle.usedMem, handle.width, handle.height, pitchInBytes,
        min(quality, handle.previousFrame.depth + 160 / max(1, handle.previousFrame.count)));

    buffer: *MsfGifBuffer;
    buffer = msf_compress_frame(handle.width, handle.height,
        centiSecondsPerFrame, handle.currentFrame, handle, handle.usedMem, handle.tlbMem, handle.lzwMem);

    if !buffer {
        msf_free_gif_state(handle);
        return 0;
    }

    handle.listTail.next = buffer;
    handle.listTail = buffer;

    //swap current and previous frames
    tmp := handle.previousFrame;
    handle.previousFrame = handle.currentFrame;
    handle.currentFrame = tmp;

    handle.framesSubmitted += 1;
    return 1;
}


/**
 * @return                     A block of memory containing the gif file data, or null on error.
 *                             You are responsible for freeing this via `msf_gif_free()`.
 */
msf_gif_end :: (handle: *MsfGifState) -> MsfGifResult {
    //profile->MsfTimeFunc
    if !handle.listHead return .{};

    //first pass: determine total size
    total: msf_size_t = 1; //1 byte for trailing marker
    start := handle.listHead;
    while start {
        total += start.size;
        start = start.next;
    }

    //second pass: write data
    buffer := cast(*u8) alloc(total);
    if buffer {
        writeHead: *u8 = buffer;

        start := handle.listHead;
        while start {
            memcpy(writeHead, *start.data[0], start.size);
            writeHead += start.size;
            start = start.next;
        }

        //?
        (writeHead + 1).* = 0x3B; //#char "something"?
    }

    //third pass: free buffers
    msf_free_gif_state(handle);

    result := MsfGifResult.{ buffer, total, total, handle.customAllocatorContext };
    return result;
}

// void msf_gif_free(MsfGifResult result) { MsfTimeFunc
//     if (result.data) { MSF_GIF_FREE(result.contextPointer, result.data, result.allocSize); }
// }
/*
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2025 Miles Fogle
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
ALTERNATIVE B - Public Domain (www.unlicense.org)
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.
In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
------------------------------------------------------------------------------
*/
