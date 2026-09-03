// ABOUTME: Element-by-element decoding for the user-owned lists Atelier keeps in UserDefaults.
// ABOUTME: One record the current shape cannot read must not discard the records it can.

import Foundation

/// Reading for the small JSON lists Atelier holds on the user's behalf — their
/// projects and their stored prompts.
///
/// Both were read with a single `try?` over the whole array, which made every
/// element a single point of failure for all of them: a workstream written by an
/// older build, a key that changed shape, one hand-edited entry, and the list
/// came back empty. Empty is not a neutral answer here, because the next edit
/// saves it back over the blob — so the list did not merely fail to load, it was
/// destroyed, silently, by the app that was meant to be keeping it.
///
/// Two rules follow. Decode one element at a time, so a record that cannot be
/// read costs only itself. And never let a partial read overwrite the bytes it
/// could not read: whatever came off disk is copied aside first, under
/// `unreadableKeySuffix`, where a later version — or the user — can still get at
/// it.
enum LossyStore {
    /// Appended to a storage key for the copy kept when a read was not complete.
    /// Always the last blob that could not be read in full, so a second failure
    /// replaces the first rather than accumulating.
    static let unreadableKeySuffix = ".unreadable"

    /// Decodes `[T]` from `key`, skipping elements that fail.
    ///
    /// Nil means "nothing of the user's could be read here" — the key is absent,
    /// the blob is not an array, or not one element survived — and is the
    /// caller's cue to fall back. An empty array is the different, meaningful
    /// answer that the user really has none, which `StoredPromptStore` is
    /// documented to preserve rather than re-seed. Conflating the two is how a
    /// failed read becomes a deletion.
    ///
    /// Whenever anything is dropped, the original blob is preserved first.
    static func loadArray<T: Decodable>(
        _: T.Type,
        forKey key: String,
        from defaults: UserDefaults,
        decoder: JSONDecoder = JSONDecoder()
    ) -> [T]? {
        guard let data = defaults.data(forKey: key) else { return nil }

        guard let wrapped = try? decoder.decode([Lossy<T>].self, from: data) else {
            // Not an array at all: nothing to salvage element-wise, and nothing
            // to hand back. Keep the bytes.
            preserve(data, forKey: key, in: defaults)
            return nil
        }

        let values = wrapped.compactMap(\.value)
        guard values.count == wrapped.count else {
            preserve(data, forKey: key, in: defaults)
            return values.isEmpty ? nil : values
        }
        return values
    }

    private static func preserve(_ data: Data, forKey key: String, in defaults: UserDefaults) {
        defaults.set(data, forKey: key + unreadableKeySuffix)
    }
}

/// Decodes `T`, or nothing, without failing the container it sits in.
///
/// The unkeyed container advances by one element per `decode` call whatever
/// happens inside this initializer, so a single unreadable element does not
/// derail the elements after it.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a nested array element by element, skipping elements that fail.
    ///
    /// The array itself is still required: a *missing* key is a different problem
    /// from an unreadable element, and silently substituting an empty list would
    /// hide it.
    func decodeLossyArray<T: Decodable>(_: T.Type, forKey key: Key) throws -> [T] {
        try decode([Lossy<T>].self, forKey: key).compactMap(\.value)
    }
}
