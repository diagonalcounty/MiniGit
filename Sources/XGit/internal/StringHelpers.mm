//
//  StringHelpers.mm
//  Various functions and structs to help with NSString conversion in C++ code
//
//  Created by Lightech on 10/24/2048.
//

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Ill-formed UTF-8 (truncated sequences, overlong encodings, surrogates,
// bytes above U+10FFFF). NSString's UTF-8 initializer funnels into
// __CFStringCreateImmutableFunnel3, which traps with EXC_BREAKPOINT on
// those buffers instead of returning nil. Callers must validate first.
static BOOL BufferIsValidUTF8(const char * _Nonnull text, size_t length) {
    const unsigned char *bytes = (const unsigned char *)text;
    size_t i = 0;

    while (i < length) {
        unsigned char c = bytes[i];
        if (c <= 0x7F) {
            i += 1;
            continue;
        }

        size_t remaining;
        unsigned int codepoint;
        if ((c & 0xE0) == 0xC0) {
            if (c < 0xC2)
                return NO;
            remaining = 1;
            codepoint = c & 0x1F;
        } else if ((c & 0xF0) == 0xE0) {
            remaining = 2;
            codepoint = c & 0x0F;
        } else if ((c & 0xF8) == 0xF0) {
            if (c > 0xF4)
                return NO;
            remaining = 3;
            codepoint = c & 0x07;
        } else {
            return NO;
        }

        // `i < length`, so `length - i` does not wrap. Need `remaining`
        // bytes after `bytes[i]`.
        if (length - i <= remaining)
            return NO;

        for (size_t j = 1; j <= remaining; j++) {
            unsigned char continuation = bytes[i + j];
            if ((continuation & 0xC0) != 0x80)
                return NO;
            codepoint = (codepoint << 6) | (continuation & 0x3F);
        }

        if (remaining == 2) {
            if (codepoint < 0x800 || (codepoint >= 0xD800 && codepoint <= 0xDFFF))
                return NO;
        } else if (remaining == 3) {
            if (codepoint < 0x10000 || codepoint > 0x10FFFF)
                return NO;
        }

        i += remaining + 1;
    }

    return YES;
}

// `length` is the byte count to decode. The copy is NUL-terminated so a
// one-past peek cannot walk off a buffer that libgit2 did not terminate,
// but the NSString is still built from `length` bytes (embedded NULs stay).
static NSString * _Nullable StringFromBytes(const char * _Nonnull text, size_t length, NSStringEncoding encoding) {
    if (length == 0)
        return @"";
    if (length == SIZE_MAX)
        return nil;

    char *copy = (char *)malloc(length + 1);
    if (copy == NULL)
        return nil;

    memcpy(copy, text, length);
    copy[length] = '\0';

    NSString *decoded = [[NSString alloc] initWithBytes:copy length:(NSUInteger)length encoding:encoding];
    free(copy);
    return decoded;
}

static NSString * _Nullable NSStringFromCString(const char * _Nullable text) {
    if (text == NULL)
        return nil;

    return [NSString stringWithUTF8String:text];
}

// Never nil and never traps. NULL or zero length is @"". Valid UTF-8 is
// decoded as UTF-8; anything else is ISO Latin-1, which accepts every byte.
static NSString * _Nonnull NSStringFromBuffer(const char * _Nullable text, size_t length) {
    if (text == NULL || length == 0)
        return @"";

    if (BufferIsValidUTF8(text, length)) {
        NSString *utf8 = StringFromBytes(text, length, NSUTF8StringEncoding);
        return utf8 != nil ? utf8 : @"";
    }

    NSString *latin1 = StringFromBytes(text, length, NSISOLatin1StringEncoding);
    return latin1 != nil ? latin1 : @"";
}
