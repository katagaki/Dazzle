import SwiftUI

/// Undo and redo for a document's presentation.
///
/// Every change to the presentation, however it was made, passes through
/// `record(from:to:)`, which registers the presentation as it was with the
/// document's undo manager. Snapshots rather than inverse operations: the
/// presentation is a value with copy-on-write storage, so a snapshot shares
/// everything the change left alone, and no edit can forget to be undoable.
@MainActor
@Observable
final class DeckHistory {
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// How long a pause ends a run of typing that would otherwise be one step.
    static let coalescingInterval: TimeInterval = 1
    static let levels = 100

    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var read: () -> Presentation = { .blank }
    @ObservationIgnored private var write: (Presentation) -> Void = { _ in /* Replaced on attach. */ }
    /// Told after an undo or redo has put a presentation back.
    @ObservationIgnored private var restored: (Presentation) -> Void = { _ in /* Replaced on attach. */ }

    /// The presentation an undo or redo has just written. SwiftUI reports
    /// the change a moment later; recognising it keeps that report off the stack.
    @ObservationIgnored private var restoring: Presentation?
    @ObservationIgnored private var lastScope: ChangeScope?
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func attach(
        to undoManager: UndoManager?,
        read: @escaping () -> Presentation,
        write: @escaping (Presentation) -> Void,
        restored: @escaping (Presentation) -> Void
    ) {
        self.read = read
        self.write = write
        self.restored = restored
        guard undoManager !== self.undoManager else { return }
        self.undoManager = undoManager
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let undoManager else { return refresh() }
        undoManager.levelsOfUndo = Self.levels
        let names: [Notification.Name] = [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    /// Notes a change the user made, unless it is one an undo or redo made.
    func record(from old: Presentation, to new: Presentation) {
        if let restoring {
            self.restoring = nil
            if restoring == new { return }
        }
        guard let undoManager, old != new else { return }

        let scope = ChangeScope(from: old, to: new)
        let now = Date()
        defer {
            lastScope = scope
            lastChange = now
        }
        // A run of typing into one shape, or into the notes, is one step.
        if scope.coalesces, scope == lastScope, undoManager.canUndo,
           now.timeIntervalSince(lastChange) < Self.coalescingInterval {
            return
        }
        register(restoring: old, with: undoManager)
        refresh()
    }

    func undo() {
        guard let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
        refresh()
    }

    func redo() {
        guard let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
        refresh()
    }

    private func register(restoring target: Presentation, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                let current = history.read()
                history.register(restoring: current, with: undoManager)
                history.lastScope = nil
                history.restoring = target
                history.write(target)
                history.restored(target)
            }
        }
    }

    private func refresh() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

/// What kind of change was made, for deciding whether it continues the last.
private enum ChangeScope: Equatable {
    case text(slide: Slide.ID, shape: SlideShape.ID)
    case notes(slide: Slide.ID)
    case other

    init(from old: Presentation, to new: Presentation) {
        self = .other
        guard old.slides.count == new.slides.count else { return }
        let changed = zip(old.slides, new.slides).filter { $0 != $1 }
        guard changed.count == 1, let (before, after) = changed.first, before.id == after.id else { return }
        if before.notes != after.notes, before.shapes == after.shapes {
            self = .notes(slide: after.id)
            return
        }
        let shapes = zip(before.shapes, after.shapes).filter { $0 != $1 }
        if before.shapes.count == after.shapes.count, shapes.count == 1, let (was, now) = shapes.first,
           was.id == now.id, was.frame == now.frame, was.text != now.text {
            self = .text(slide: after.id, shape: now.id)
        }
    }

    var coalesces: Bool { self != .other }
}
