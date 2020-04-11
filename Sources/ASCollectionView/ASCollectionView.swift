// ASCollectionView. Created by Apptek Studios 2019

import Combine
import SwiftUI

// MARK: Init for single-section CV

@available(iOS 13.0, *)
extension ASCollectionView where SectionID == Int
{
	/**
	 Initializes a  collection view with a single section.

	 - Parameters:
	 	- section: A single section (ASCollectionViewSection)
	 */
	public init(section: Section)
	{
		sections = [section]
	}

	/**
	 Initializes a  collection view with a single section of static content
	 */
	public init(@ViewArrayBuilder staticContent: () -> ViewArrayBuilder.Wrapper)
	{
		self.init(sections: [ASCollectionViewSection(id: 0, content: staticContent)])
	}

	/**
	 Initializes a  collection view with a single section.
	 */
	public init<DataCollection: RandomAccessCollection, DataID: Hashable, Content: View>(
		data: DataCollection,
		dataID dataIDKeyPath: KeyPath<DataCollection.Element, DataID>,
		@ViewBuilder contentBuilder: @escaping ((DataCollection.Element, CellContext) -> Content))
		where DataCollection.Index == Int
	{
		let section = ASCollectionViewSection(
			id: 0,
			data: data,
			dataID: dataIDKeyPath,
			contentBuilder: contentBuilder)
		sections = [section]
	}

	/**
	 Initializes a  collection view with a single section with identifiable data
	 */
	public init<DataCollection: RandomAccessCollection, Content: View>(
		data: DataCollection,
		@ViewBuilder contentBuilder: @escaping ((DataCollection.Element, CellContext) -> Content))
		where DataCollection.Index == Int, DataCollection.Element: Identifiable
	{
		self.init(data: data, dataID: \.id, contentBuilder: contentBuilder)
	}
}

@available(iOS 13.0, *)
public struct ASCollectionView<SectionID: Hashable>: UIViewControllerRepresentable, ContentSize
{
	// MARK: Type definitions

	public typealias Section = ASCollectionViewSection<SectionID>
	public typealias Layout = ASCollectionLayout<SectionID>

	public typealias OnScrollCallback = ((_ contentOffset: CGPoint, _ contentSize: CGSize) -> Void)
	public typealias OnReachedBoundaryCallback = ((_ boundary: Boundary) -> Void)

	// MARK: Key variables

	public var layout: Layout = .default
	public var sections: [Section]

	// MARK: Internal variables modified by modifier functions

	private var delegateInitialiser: (() -> ASCollectionViewDelegate) = ASCollectionViewDelegate.init

	internal var contentSizeTracker: ContentSizeTracker?

	private var onScrollCallback: OnScrollCallback?
	private var onReachedBoundaryCallback: OnReachedBoundaryCallback?

	private var horizontalScrollIndicatorEnabled: Bool = true
	private var verticalScrollIndicatorEnabled: Bool = true
	private var contentInsets: UIEdgeInsets = .zero

	private var onPullToRefresh: ((_ endRefreshing: @escaping (() -> Void)) -> Void)?

	private var alwaysBounceVertical: Bool = false
	private var alwaysBounceHorizontal: Bool = false

	private var initialScrollPosition: ASCollectionViewScrollPosition?

	private var animateOnDataRefresh: Bool = true

	private var maintainScrollPositionOnOrientationChange: Bool = true

	private var shouldInvalidateLayoutOnStateChange: Bool = false
	private var shouldAnimateInvalidatedLayoutOnStateChange: Bool = false

	private var shouldRecreateLayoutOnStateChange: Bool = false
	private var shouldAnimateRecreatedLayoutOnStateChange: Bool = false

	// MARK: Environment variables

	// SwiftUI environment
	@Environment(\.editMode) private var editMode

	// MARK: Init for multi-section CVs

	/**
	 Initializes a  collection view with the given sections

	 - Parameters:
	 	- sections: An array of sections (ASCollectionViewSection)
	 */
	@inlinable public init(sections: [Section])
	{
		self.sections = sections
	}

	@inlinable public init(@SectionArrayBuilder <SectionID> sectionBuilder: () -> [Section])
	{
		sections = sectionBuilder()
	}

	public func makeUIViewController(context: Context) -> AS_CollectionViewController
	{
		context.coordinator.parent = self

		let delegate = delegateInitialiser()
		delegate.coordinator = context.coordinator

		let collectionViewLayout = layout.makeLayout(withCoordinator: context.coordinator)

		let collectionViewController = AS_CollectionViewController(collectionViewLayout: collectionViewLayout)
		collectionViewController.coordinator = context.coordinator

		context.coordinator.collectionViewController = collectionViewController
		context.coordinator.delegate = delegate

		context.coordinator.updateCollectionViewSettings(collectionViewController.collectionView)
		context.coordinator.setupDataSource(forCollectionView: collectionViewController.collectionView)

		return collectionViewController
	}

	public func updateUIViewController(_ collectionViewController: AS_CollectionViewController, context: Context)
	{
		context.coordinator.parent = self
		context.coordinator.updateCollectionViewSettings(collectionViewController.collectionView)
		context.coordinator.updateLayout()
		context.coordinator.updateContent(collectionViewController.collectionView, transaction: context.transaction, refreshExistingCells: true)
		context.coordinator.configureRefreshControl(for: collectionViewController.collectionView)
#if DEBUG
		debugOnly_checkHasUniqueSections()
#endif
	}

	public func makeCoordinator() -> Coordinator
	{
		Coordinator(self)
	}

#if DEBUG
	func debugOnly_checkHasUniqueSections()
	{
		var sectionIDs: Set<SectionID> = []
		var conflicts: Set<SectionID> = []
		sections.forEach {
			let (inserted, _) = sectionIDs.insert($0.id)
			if !inserted
			{
				conflicts.insert($0.id)
			}
		}
		if !conflicts.isEmpty
		{
			print("ASCOLLECTIONVIEW: The following section IDs are used more than once, please use unique section IDs to avoid unexpected behaviour:", sectionIDs)
		}
	}
#endif

	// MARK: Coordinator Class

	public class Coordinator: ASCollectionViewCoordinator
	{
		var parent: ASCollectionView
		var delegate: ASCollectionViewDelegate?

		weak var collectionViewController: AS_CollectionViewController?

		var dataSource: ASDiffableDataSourceCollectionView<SectionID>?

		let cellReuseID = UUID().uuidString
		let supplementaryReuseID = UUID().uuidString

		// MARK: Private tracking variables

		private var hasDoneInitialSetup = false
		private var hasFiredBoundaryNotificationForBoundary: Set<Boundary> = []

		private var haveRegisteredForSupplementaryOfKind: Set<String> = []

		// MARK: Caching

		private var autoCachingHostingControllers = ASPriorityCache<ASCollectionViewItemUniqueID, ASHostingControllerProtocol>()
		private var explicitlyCachedHostingControllers: [ASCollectionViewItemUniqueID: ASHostingControllerProtocol] = [:]

		typealias Cell = ASCollectionViewCell

		init(_ parent: ASCollectionView)
		{
			self.parent = parent
		}

		func sectionID(fromSectionIndex sectionIndex: Int) -> SectionID?
		{
			parent.sections[safe: sectionIndex]?.id
		}

		func section(forItemID itemID: ASCollectionViewItemUniqueID) -> Section?
		{
			parent.sections
				.first(where: { $0.id.hashValue == itemID.sectionIDHash })
		}

		func supplementaryKinds() -> Set<String>
		{
			parent.sections.reduce(into: Set<String>()) { result, section in
				result.formUnion(section.supplementaryKinds)
			}
		}

		func registerSupplementaries(forCollectionView cv: UICollectionView)
		{
			supplementaryKinds().subtracting(haveRegisteredForSupplementaryOfKind).forEach
			{ kind in
				cv.register(ASCollectionViewSupplementaryView.self, forSupplementaryViewOfKind: kind, withReuseIdentifier: supplementaryReuseID)
				self.haveRegisteredForSupplementaryOfKind.insert(kind) // We don't need to register this kind again now.
			}
		}

		func updateCollectionViewSettings(_ collectionView: UICollectionView)
		{
			assignIfChanged(collectionView, \.dragInteractionEnabled, newValue: true)
			assignIfChanged(collectionView, \.contentInsetAdjustmentBehavior, newValue: delegate?.collectionViewContentInsetAdjustmentBehavior ?? .automatic)
			assignIfChanged(collectionView, \.contentInset, newValue: parent.contentInsets)
			assignIfChanged(collectionView, \.alwaysBounceVertical, newValue: parent.alwaysBounceVertical)
			assignIfChanged(collectionView, \.alwaysBounceHorizontal, newValue: parent.alwaysBounceHorizontal)
			assignIfChanged(collectionView, \.showsVerticalScrollIndicator, newValue: parent.verticalScrollIndicatorEnabled)
			assignIfChanged(collectionView, \.showsHorizontalScrollIndicator, newValue: parent.horizontalScrollIndicatorEnabled)

			let isEditing = parent.editMode?.wrappedValue.isEditing ?? false
			assignIfChanged(collectionView, \.allowsSelection, newValue: isEditing)
			assignIfChanged(collectionView, \.allowsMultipleSelection, newValue: isEditing)
		}

		func setupDataSource(forCollectionView cv: UICollectionView)
		{
			cv.delegate = delegate
			cv.dragDelegate = delegate
			cv.dropDelegate = delegate

			cv.register(Cell.self, forCellWithReuseIdentifier: cellReuseID)

			dataSource = .init(collectionView: cv)
			{ [weak self] collectionView, indexPath, itemID in
				guard let self = self else { return nil }

				guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: self.cellReuseID, for: indexPath) as? Cell
				else { return nil }

				guard let section = self.parent.sections[safe: indexPath.section] else { return cell }

				cell.collectionView = collectionView

				cell.invalidateLayoutCallback = { [weak self] animated in
					self?.invalidateLayout(animated: animated)
				}
				cell.scrollToCellCallback = { [weak self] position in
					self?.scrollToItem(indexPath: indexPath, position: position)
				}

				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .content, indexPath: indexPath)
				cell.selfSizingConfig =
					section.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? self.delegate?.collectionViewSelfSizingSettings(forContext: selfSizingContext)
						?? (collectionView.collectionViewLayout as? ASCollectionViewLayoutProtocol)?.selfSizingConfig
						?? ASSelfSizingConfig(selfSizeHorizontally: true, selfSizeVertically: true)

				// Set itemID
				cell.itemID = itemID

				// Update hostingController
				let cachedHC = self.explicitlyCachedHostingControllers[itemID] ?? self.autoCachingHostingControllers[itemID]
				cell.hostingController = section.dataSource.updateOrCreateHostController(forItemID: itemID, existingHC: cachedHC)

				// Cache the HC
				self.autoCachingHostingControllers[itemID] = cell.hostingController
				if section.shouldCacheCells
				{
					self.explicitlyCachedHostingControllers[itemID] = cell.hostingController
				}

				return cell
			}
			dataSource?.supplementaryViewProvider = { [weak self] cv, kind, indexPath in
				guard let self = self else { return nil }

				guard self.supplementaryKinds().contains(kind) else
				{
					return nil
				}
				guard let reusableView = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: self.supplementaryReuseID, for: indexPath) as? ASCollectionViewSupplementaryView
				else { return nil }

				// Self Sizing Settings
				let selfSizingContext = ASSelfSizingContext(cellType: .supplementary(kind), indexPath: indexPath)
				reusableView.selfSizingConfig =
					self.parent.sections[safe: indexPath.section]?.dataSource.getSelfSizingSettings(context: selfSizingContext)
						?? self.delegate?.collectionViewSelfSizingSettings(forContext: selfSizingContext)
						?? ASSelfSizingConfig(selfSizeHorizontally: true, selfSizeVertically: true)

				if let supplementaryView = self.parent.sections[safe: indexPath.section]?.supplementary(ofKind: kind)
				{
					reusableView.setupFor(
						id: indexPath.section,
						view: supplementaryView)
				}
				else
				{
					reusableView.setupForEmpty(id: indexPath.section)
				}

				return reusableView
			}
			setupPrefetching()
		}

		func populateDataSource(animated: Bool = true)
		{
			guard hasDoneInitialSetup else { return }
			collectionViewController.map { registerSupplementaries(forCollectionView: $0.collectionView) } // New sections might involve new types of supplementary...
			let snapshot = ASDiffableDataSourceSnapshot(sections:
				parent.sections.map {
					ASDiffableDataSourceSnapshot.Section(id: $0.id, elements: $0.itemIDs)
				}
			)
			dataSource?.applySnapshot(snapshot, animated: animated)
			collectionViewController.map { self.didUpdateContentSize($0.collectionView.contentSize) }
		}

		func updateContent(_ cv: UICollectionView, transaction: Transaction?, refreshExistingCells: Bool)
		{
			guard hasDoneInitialSetup else { return }

			if refreshExistingCells
			{
				withAnimation(parent.animateOnDataRefresh ? transaction?.animation : nil) {
					refreshVisibleCells()
				}
			}
			let transactionAnimationEnabled = (transaction?.animation != nil) && !(transaction?.disablesAnimations ?? false)
			populateDataSource(animated: parent.animateOnDataRefresh && transactionAnimationEnabled)
			updateSelectionBindings(cv)
		}

		func refreshVisibleCells()
		{
			guard let cv = collectionViewController?.collectionView else { return }
			for case let cell as Cell in cv.visibleCells
			{
				guard
					let itemID = cell.itemID,
					let hc = cell.hostingController
				else { return }
				self.section(forItemID: itemID)?.dataSource.update(hc, forItemID: itemID)
			}

			supplementaryKinds().forEach
			{ kind in
				cv.indexPathsForVisibleSupplementaryElements(ofKind: kind).forEach
				{
					guard let supplementaryView = parent.sections[safe: $0.section]?.supplementary(ofKind: kind) else { return }
					(cv.supplementaryView(forElementKind: kind, at: $0) as? ASCollectionViewSupplementaryView)?
						.setupFor(
							id: $0.section,
							view: supplementaryView)
				}
			}
		}

		func onMoveToParent()
		{
			if !hasDoneInitialSetup
			{
				hasDoneInitialSetup = true

				// Populate data source
				populateDataSource(animated: false)

				// Set initial scroll position
				parent.initialScrollPosition.map { scrollToPosition($0, animated: false) }
			}
		}

		func onMoveFromParent()
		{}

		func invalidateLayout(animated: Bool)
		{
			CATransaction.begin()
			if !animated
			{
				CATransaction.setDisableActions(true)
			}
			collectionViewController?.collectionViewLayout.invalidateLayout()
			CATransaction.commit()
		}

		func configureRefreshControl(for cv: UICollectionView)
		{
			guard parent.onPullToRefresh != nil else
			{
				if cv.refreshControl != nil
				{
					cv.refreshControl = nil
				}
				return
			}
			if cv.refreshControl == nil
			{
				let refreshControl = UIRefreshControl()
				refreshControl.addTarget(self, action: #selector(collectionViewDidPullToRefresh), for: .valueChanged)
				cv.refreshControl = refreshControl
			}
		}

		@objc
		public func collectionViewDidPullToRefresh()
		{
			guard let collectionView = collectionViewController?.collectionView else { return }
			let endRefreshing: (() -> Void) = { [weak collectionView] in
				collectionView?.refreshControl?.endRefreshing()
			}
			parent.onPullToRefresh?(endRefreshing)
		}

		// MARK: Functions for determining scroll position (on appear, and also on orientation change)

		func scrollToItem(indexPath: IndexPath, position: UICollectionView.ScrollPosition = [])
		{
			CATransaction.begin()
			collectionViewController?.collectionView.scrollToItem(at: indexPath, at: position, animated: true)
			CATransaction.commit()
		}

		func scrollToPosition(_ scrollPosition: ASCollectionViewScrollPosition, animated: Bool = false)
		{
			switch scrollPosition
			{
			case .top, .left:
				collectionViewController?.collectionView.setContentOffset(.zero, animated: animated)
			case .bottom:
				guard let maxOffset = collectionViewController?.collectionView.maxContentOffset else { return }
				collectionViewController?.collectionView.setContentOffset(.init(x: 0, y: maxOffset.y), animated: animated)
			case .right:
				guard let maxOffset = collectionViewController?.collectionView.maxContentOffset else { return }
				collectionViewController?.collectionView.setContentOffset(.init(x: maxOffset.x, y: 0), animated: animated)
			case let .centerOnIndexPath(indexPath):
				guard let offset = getContentOffsetToCenterCell(at: indexPath) else { return }
				collectionViewController?.collectionView.setContentOffset(offset, animated: animated)
			}
		}

		func prepareForOrientationChange()
		{
			guard let collectionView = collectionViewController?.collectionView else { return }

			if parent.maintainScrollPositionOnOrientationChange
			{
				// Get centremost cell
				if let indexPath = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: collectionView.bounds.midY))
				{
					// Item at centre
					transitionCentralIndexPath = indexPath
				}
				else if let visibleCells = collectionViewController?.collectionView.indexPathsForVisibleItems, !visibleCells.isEmpty
				{
					// Approximate item at centre
					transitionCentralIndexPath = visibleCells[visibleCells.count / 2]
				}
				else
				{
					transitionCentralIndexPath = nil
				}
			}
		}

		var transitionCentralIndexPath: IndexPath?
		func getContentOffsetForOrientationChange() -> CGPoint?
		{
			if parent.maintainScrollPositionOnOrientationChange
			{
				guard let currentOffset = collectionViewController?.collectionView.contentOffset, currentOffset.x > 0, currentOffset.y > 0 else { return nil }
				return transitionCentralIndexPath.flatMap(getContentOffsetToCenterCell)
			}
			else
			{
				return nil
			}
		}

		func completedOrientationChange()
		{
			transitionCentralIndexPath = nil
		}

		func getContentOffsetToCenterCell(at indexPath: IndexPath) -> CGPoint?
		{
			guard
				let collectionView = collectionViewController?.collectionView,
				let centerCellFrame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
			else { return nil }
			let maxOffset = collectionView.maxContentOffset
			let newOffset = CGPoint(
				x: max(0, min(maxOffset.x, centerCellFrame.midX - (collectionView.bounds.width / 2))),
				y: max(0, min(maxOffset.y, centerCellFrame.midY - (collectionView.bounds.height / 2))))
			return newOffset
		}

		// MARK: Functions for updating layout

		func updateLayout()
		{
			guard let collectionViewController = collectionViewController else { return }
			// Configure any custom layout
			parent.layout.configureLayout(layoutObject: collectionViewController.collectionView.collectionViewLayout)

			// If enabled, recreate the layout
			if parent.shouldRecreateLayoutOnStateChange
			{
				let newLayout = parent.layout.makeLayout(withCoordinator: self)
				collectionViewController.collectionView.setCollectionViewLayout(newLayout, animated: parent.shouldAnimateRecreatedLayoutOnStateChange && hasDoneInitialSetup)
			}
			// If enabled, invalidate the layout
			else if parent.shouldInvalidateLayoutOnStateChange
			{
				let changes = {
					collectionViewController.collectionViewLayout.invalidateLayout()
					collectionViewController.collectionView.layoutIfNeeded()
				}
				if parent.shouldAnimateInvalidatedLayoutOnStateChange, hasDoneInitialSetup
				{
					UIView.animate(
						withDuration: 0.4,
						delay: 0.0,
						usingSpringWithDamping: 1.0,
						initialSpringVelocity: 0.0,
						options: UIView.AnimationOptions(),
						animations: changes,
						completion: nil)
				}
				else
				{
					changes()
				}
			}
		}

		// MARK: CollectionViewDelegate functions

		// NOTE: These are not called directly, but rather forwarded to the Coordinator by the ASCollectionViewDelegate class

		public func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath)
		{
			collectionViewController.map { (cell as? Cell)?.willAppear(in: $0) }
			currentlyPrefetching.remove(indexPath)
			guard !indexPath.isEmpty else { return }
			parent.sections[safe: indexPath.section]?.dataSource.onAppear(indexPath)
			queuePrefetch.send()
		}

		public func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath)
		{
			(cell as? Cell)?.didDisappear()
			guard !indexPath.isEmpty else { return }
			parent.sections[safe: indexPath.section]?.dataSource.onDisappear(indexPath)
		}

		public func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView, forElementKind elementKind: String, at indexPath: IndexPath)
		{
			(view as? ASCollectionViewSupplementaryView)?.willAppear(in: collectionViewController)
		}

		public func collectionView(_ collectionView: UICollectionView, didEndDisplayingSupplementaryView view: UICollectionReusableView, forElementOfKind elementKind: String, at indexPath: IndexPath)
		{
			(view as? ASCollectionViewSupplementaryView)?.didDisappear()
		}

		public func collectionView(_ collectionView: UICollectionView, willSelectItemAt indexPath: IndexPath) -> IndexPath?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.shouldSelect(indexPath) ?? true else
			{
				return nil
			}
			return indexPath
		}

		public func collectionView(_ collectionView: UICollectionView, willDeselectItemAt indexPath: IndexPath) -> IndexPath?
		{
			guard parent.sections[safe: indexPath.section]?.dataSource.shouldDeselect(indexPath) ?? true else
			{
				return nil
			}
			return indexPath
		}

		public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
		{
			updateSelectionBindings(collectionView)
		}

		public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath)
		{
			updateSelectionBindings(collectionView)
		}

		func updateSelectionBindings(_ collectionView: UICollectionView)
		{
			let selected = collectionView.indexPathsForSelectedItems ?? []
			let selectionBySection = Dictionary(grouping: selected) { $0.section }
				.mapValues
			{
				Set($0.map { $0.item })
			}
			parent.sections.enumerated().forEach { offset, section in
				section.dataSource.updateSelection(selectionBySection[offset] ?? [])
			}
		}

		func canDrop(at indexPath: IndexPath) -> Bool
		{
			guard !indexPath.isEmpty else { return false }
			return parent.sections[safe: indexPath.section]?.dataSource.dropEnabled ?? false
		}

		func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem]
		{
			guard !indexPath.isEmpty else { return [] }
			guard let dragItem = parent.sections[safe: indexPath.section]?.dataSource.getDragItem(for: indexPath) else { return [] }
			return [dragItem]
		}

		func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal
		{
			if collectionView.hasActiveDrag
			{
				if let destination = destinationIndexPath
				{
					guard canDrop(at: destination) else
					{
						return UICollectionViewDropProposal(operation: .cancel)
					}
				}
				return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
			}
			else
			{
				return UICollectionViewDropProposal(operation: .copy, intent: .insertAtDestinationIndexPath)
			}
		}

		func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator)
		{
			guard
				let destinationIndexPath = coordinator.destinationIndexPath,
				!destinationIndexPath.isEmpty,
				let destinationSection = parent.sections[safe: destinationIndexPath.section]
			else { return }

			guard canDrop(at: destinationIndexPath) else { return }

			guard let oldSnapshot = dataSource?.currentSnapshot else { return }
			var dragSnapshot = oldSnapshot

			switch coordinator.proposal.operation
			{
			case .move:
				guard destinationSection.dataSource.reorderingEnabled else { return }
				let itemsBySourceSection = Dictionary(grouping: coordinator.items) { item -> Int? in
					if let sourceIndex = item.sourceIndexPath, !sourceIndex.isEmpty
					{
						return sourceIndex.section
					}
					else
					{
						return nil
					}
				}

				let sourceSections = itemsBySourceSection.keys.sorted { a, b in
					guard let a = a else { return false }
					guard let b = b else { return true }
					return a < b
				}

				var itemsToInsert: [UICollectionViewDropItem] = []

				for sourceSectionIndex in sourceSections
				{
					guard let items = itemsBySourceSection[sourceSectionIndex] else { continue }

					if
						let sourceSectionIndex = sourceSectionIndex,
						let sourceSection = parent.sections[safe: sourceSectionIndex]
					{
						guard sourceSection.dataSource.reorderingEnabled else { continue }

						let sourceIndices = items.compactMap { $0.sourceIndexPath?.item }

						// Remove from source section
						dragSnapshot.sections[sourceSectionIndex].elements.remove(atOffsets: IndexSet(sourceIndices))
						sourceSection.dataSource.applyRemove(atOffsets: IndexSet(sourceIndices))
					}

					// Add to insertion array (regardless whether sourceSection is nil)
					itemsToInsert.append(contentsOf: items)
				}

				let itemsToInsertIDs: [ASCollectionViewItemUniqueID] = itemsToInsert.compactMap { item in
					if let sourceIndexPath = item.sourceIndexPath
					{
						return oldSnapshot.sections[sourceIndexPath.section].elements[sourceIndexPath.item]
					}
					else
					{
						return destinationSection.dataSource.getItemID(for: item.dragItem, withSectionID: destinationSection.id)
					}
				}
				dragSnapshot.sections[destinationIndexPath.section].elements.insert(contentsOf: itemsToInsertIDs, at: destinationIndexPath.item)
				destinationSection.dataSource.applyInsert(items: itemsToInsert.map { $0.dragItem }, at: destinationIndexPath.item)

			case .copy:
				destinationSection.dataSource.applyInsert(items: coordinator.items.map { $0.dragItem }, at: destinationIndexPath.item)

			default: break
			}

			dataSource?.applySnapshot(dragSnapshot)
			refreshVisibleCells()

			if let dragItem = coordinator.items.first, let destination = coordinator.destinationIndexPath
			{
				if dragItem.sourceIndexPath != nil
				{
					coordinator.drop(dragItem.dragItem, toItemAt: destination)
				}
			}
		}

		func typeErasedDataForItem(at indexPath: IndexPath) -> Any?
		{
			guard !indexPath.isEmpty else { return nil }
			return parent.sections[safe: indexPath.section]?.dataSource.getTypeErasedData(for: indexPath)
		}

		// MARK: Functions for updating contentSize binding

		var lastContentSize: CGSize = .zero
		func didUpdateContentSize(_ size: CGSize)
		{
			guard let cv = collectionViewController?.collectionView, cv.contentSize != lastContentSize else { return }
			lastContentSize = cv.contentSize
			parent.contentSizeTracker?.contentSize = size
		}

		// MARK: Variables used for the custom prefetching implementation

		private let queuePrefetch = PassthroughSubject<Void, Never>()
		private var prefetchSubscription: AnyCancellable?
		private var currentlyPrefetching: Set<IndexPath> = []
	}
}

// MARK: OnScroll/OnReachedBoundary support

@available(iOS 13.0, *)
extension ASCollectionView.Coordinator
{
	public func scrollViewDidScroll(_ scrollView: UIScrollView)
	{
		parent.onScrollCallback?(scrollView.contentOffset, scrollView.contentSizePlusInsets)
		checkIfReachedBoundary(scrollView)
	}

	func checkIfReachedBoundary(_ scrollView: UIScrollView)
	{
		let scrollableHorizontally = scrollView.contentSizePlusInsets.width > scrollView.frame.size.width
		let scrollableVertically = scrollView.contentSizePlusInsets.height > scrollView.frame.size.height

		for boundary in Boundary.allCases
		{
			let hasReachedBoundary: Bool = {
				switch boundary
				{
				case .left:
					return scrollableHorizontally && scrollView.contentOffset.x <= 0
				case .top:
					return scrollableVertically && scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top
				case .right:
					return scrollableHorizontally && (scrollView.contentSizePlusInsets.width - scrollView.contentOffset.x) <= scrollView.frame.size.width
				case .bottom:
					return scrollableVertically && (scrollView.contentSizePlusInsets.height - scrollView.contentOffset.y) <= scrollView.frame.size.height
				}
			}()

			if hasReachedBoundary
			{
				// If we haven't already fired the notification, send it now
				if !hasFiredBoundaryNotificationForBoundary.contains(boundary)
				{
					hasFiredBoundaryNotificationForBoundary.insert(boundary)
					parent.onReachedBoundaryCallback?(boundary)
				}
			}
			else
			{
				// No longer at this boundary, reset so it can fire again if needed
				hasFiredBoundaryNotificationForBoundary.remove(boundary)
			}
		}
	}
}

// MARK: Context Menu Support

@available(iOS 13.0, *)
public extension ASCollectionView.Coordinator
{
	func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
	{
		guard !indexPath.isEmpty else { return nil }
		return parent.sections[safe: indexPath.section]?.dataSource.getContextMenu(for: indexPath)
	}
}

// MARK: Coordinator Protocol

@available(iOS 13.0, *)
internal protocol ASCollectionViewCoordinator: AnyObject
{
	func typeErasedDataForItem(at indexPath: IndexPath) -> Any?
	func prepareForOrientationChange()
	func getContentOffsetForOrientationChange() -> CGPoint?
	func completedOrientationChange()
	func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView, forElementKind elementKind: String, at indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, didEndDisplayingSupplementaryView view: UICollectionReusableView, forElementOfKind elementKind: String, at indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath)
	func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
	func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem]
	func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal
	func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator)
	func didUpdateContentSize(_ size: CGSize)
	func scrollViewDidScroll(_ scrollView: UIScrollView)
	func onMoveToParent()
	func onMoveFromParent()
}

// MARK: Custom Prefetching Implementation

@available(iOS 13.0, *)
extension ASCollectionView.Coordinator
{
	func setupPrefetching()
	{
		let numberToPreload = 5
		prefetchSubscription = queuePrefetch
			.collect(.byTime(DispatchQueue.main, 0.1)) // .throttle CRASHES on 13.1, fixed from 13.3 but still using .collect for 13.1 compatibility
			.compactMap
		{ [weak collectionViewController] _ in
			collectionViewController?.collectionView.indexPathsForVisibleItems
		}
		.receive(on: DispatchQueue.global(qos: .background))
		.map
		{ [weak self] visibleIndexPaths -> [Int: [IndexPath]] in
			guard let self = self else { return [:] }
			let visibleIndexPathsBySection = Dictionary(grouping: visibleIndexPaths) { $0.section }.compactMapValues
			{ (indexPaths) -> (section: Int, first: Int, last: Int)? in
				guard let first = indexPaths.min(), let last = indexPaths.max() else { return nil }
				return (section: first.section, first: first.item, last: last.item)
			}
			var toPrefetch: [Int: [IndexPath]] = visibleIndexPathsBySection.compactMapValues
			{ item in
				guard let sectionIndexPaths = self.parent.sections[safe: item.section]?.dataSource.getIndexPaths(withSectionIndex: item.section) else { return nil }
				let nextItemsInSection: ArraySlice<IndexPath> = {
					guard (item.last + 1) < sectionIndexPaths.endIndex else { return [] }
					return sectionIndexPaths[(item.last + 1) ..< min(item.last + numberToPreload + 1, sectionIndexPaths.endIndex)]
				}()
				let previousItemsInSection: ArraySlice<IndexPath> = {
					guard (item.first - 1) >= sectionIndexPaths.startIndex else { return [] }
					return sectionIndexPaths[max(sectionIndexPaths.startIndex, item.first - numberToPreload) ..< item.first]
				}()
				return Array(nextItemsInSection) + Array(previousItemsInSection)
			}
			// CHECK IF THERES AN EARLIER SECTION TO PRELOAD
			if
				let firstSection = toPrefetch.keys.min(), // FIND THE EARLIEST VISIBLE SECTION
				(firstSection - 1) >= self.parent.sections.startIndex, // CHECK THERE IS A SECTION BEFORE THIS
				let firstIndex = visibleIndexPathsBySection[firstSection]?.first, firstIndex < numberToPreload // CHECK HOW CLOSE TO THIS SECTION WE ARE
			{
				let precedingSection = firstSection - 1
				toPrefetch[precedingSection] = self.parent.sections[precedingSection].dataSource.getIndexPaths(withSectionIndex: precedingSection).suffix(numberToPreload)
			}
			// CHECK IF THERES A LATER SECTION TO PRELOAD
			if
				let lastSection = toPrefetch.keys.max(), // FIND THE LAST VISIBLE SECTION
				(lastSection + 1) < self.parent.sections.endIndex, // CHECK THERE IS A SECTION AFTER THIS
				let lastIndex = visibleIndexPathsBySection[lastSection]?.last,
				let lastSectionEndIndex = self.parent.sections[lastSection].dataSource.getIndexPaths(withSectionIndex: lastSection).last?.item,
				(lastSectionEndIndex - lastIndex) < numberToPreload // CHECK HOW CLOSE TO THIS SECTION WE ARE
			{
				let nextSection = lastSection + 1
				toPrefetch[nextSection] = Array(self.parent.sections[nextSection].dataSource.getIndexPaths(withSectionIndex: nextSection).prefix(numberToPreload))
			}
			return toPrefetch
		}
		.sink
		{ [weak self] prefetch in
			prefetch.forEach
			{ sectionIndex, toPrefetch in
				if !toPrefetch.isEmpty
				{
					self?.parent.sections[safe: sectionIndex]?.dataSource.prefetch(toPrefetch)
				}
				if
					let toCancel = self?.currentlyPrefetching.filter({ $0.section == sectionIndex }).subtracting(toPrefetch),
					!toCancel.isEmpty
				{
					self?.parent.sections[safe: sectionIndex]?.dataSource.cancelPrefetch(Array(toCancel))
				}
			}

			self?.currentlyPrefetching = Set(prefetch.flatMap { $0.value })
		}
	}
}

@available(iOS 13.0, *)
public enum ASCollectionViewScrollPosition
{
	case top
	case bottom
	case left
	case right
	case centerOnIndexPath(_: IndexPath)
}

@available(iOS 13.0, *)
public class AS_CollectionViewController: UIViewController
{
	weak var coordinator: ASCollectionViewCoordinator?
	{
		didSet
		{
			guard viewIfLoaded != nil else { return }
			collectionView.coordinator = coordinator
		}
	}

	var collectionViewLayout: UICollectionViewLayout
	lazy var collectionView: AS_UICollectionView = {
		let cv = AS_UICollectionView(frame: .zero, collectionViewLayout: collectionViewLayout)
		cv.coordinator = coordinator
		return cv
	}()

	public init(collectionViewLayout layout: UICollectionViewLayout)
	{
		collectionViewLayout = layout
		super.init(nibName: nil, bundle: nil)
	}

	required init?(coder: NSCoder)
	{
		fatalError("init(coder:) has not been implemented")
	}

	public override func didMove(toParent parent: UIViewController?)
	{
		super.didMove(toParent: parent)
		if parent != nil
		{
			coordinator?.onMoveToParent()
		}
		else
		{
			coordinator?.onMoveFromParent()
		}
	}

	public override func loadView()
	{
		view = collectionView
	}

	public override func viewDidLoad()
	{
		super.viewDidLoad()
		view.backgroundColor = .clear
	}

	public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
	{
		// Get current central cell
		self.coordinator?.prepareForOrientationChange()

		super.viewWillTransition(to: size, with: coordinator)
		// The following is a workaround to fix the interface rotation animation under SwiftUI
		view.frame = CGRect(origin: view.frame.origin, size: size)

		coordinator.animate(alongsideTransition: { _ in
			self.view.setNeedsLayout()
			self.view.layoutIfNeeded()
			if
				let desiredOffset = self.coordinator?.getContentOffsetForOrientationChange(),
				self.collectionView.contentOffset != desiredOffset
			{
				self.collectionView.contentOffset = desiredOffset
			}
		})
		{ _ in
			// Completion
			self.coordinator?.completedOrientationChange()
		}
	}

	public override func viewSafeAreaInsetsDidChange()
	{
		super.viewSafeAreaInsetsDidChange()
		// The following is a workaround to fix the interface rotation animation under SwiftUI
		collectionViewLayout.invalidateLayout()
	}

	public override func viewDidLayoutSubviews()
	{
		super.viewDidLayoutSubviews()
		coordinator?.didUpdateContentSize(collectionView.contentSize)
	}
}

@available(iOS 13.0, *)
class AS_UICollectionView: UICollectionView
{
	weak var coordinator: ASCollectionViewCoordinator?

	public override func didMoveToWindow()
	{
		super.didMoveToWindow()
		guard window != nil else { return }
		// Intended as a temporary workaround for a SwiftUI bug present in 13.3 -> the UIViewController is not moved to a parent when embedded in a list/scrollview
		coordinator?.onMoveToParent()
	}
}

// MARK: Modifer: Custom Delegate

@available(iOS 13.0, *)
public extension ASCollectionView
{
	/// Use this modifier to assign a custom delegate type (subclass of ASCollectionViewDelegate). This allows support for old UICollectionViewLayouts that require a delegate.
	func customDelegate(_ delegateInitialiser: @escaping (() -> ASCollectionViewDelegate)) -> Self
	{
		var cv = self
		cv.delegateInitialiser = delegateInitialiser
		return cv
	}
}

// MARK: Modifer: Layout Invalidation

@available(iOS 13.0, *)
public extension ASCollectionView
{
	/// For use in cases where you would like to change layout settings in response to a change in variables referenced by your layout closure.
	/// Note: this ensures the layout is invalidated
	/// - For UICollectionViewCompositionalLayout this means that your SectionLayout closure will be called again
	/// - closures capture value types when created, therefore you must refer to a reference type in your layout closure if you want it to update.
	func shouldInvalidateLayoutOnStateChange(_ shouldInvalidate: Bool, animated: Bool = true) -> Self
	{
		var this = self
		this.shouldInvalidateLayoutOnStateChange = shouldInvalidate
		this.shouldAnimateInvalidatedLayoutOnStateChange = animated
		return this
	}

	/// For use in cases where you would like to recreate the layout object in response to a change in state. Eg. for changing layout types completely
	/// If not changing the type of layout (eg. to a different class) t is preferable to invalidate the layout and update variables in the `configureCustomLayout` closure
	func shouldRecreateLayoutOnStateChange(_ shouldRecreate: Bool, animated: Bool = true) -> Self
	{
		var this = self
		this.shouldRecreateLayoutOnStateChange = shouldRecreate
		this.shouldAnimateRecreatedLayoutOnStateChange = animated
		return this
	}
}

// MARK: Modifer: Other Modifiers

@available(iOS 13.0, *)
public extension ASCollectionView
{
	/// Set a closure that is called whenever the collectionView is scrolled
	func onScroll(_ onScroll: @escaping OnScrollCallback) -> Self
	{
		var this = self
		this.onScrollCallback = onScroll
		return this
	}

	/// Set a closure that is called whenever the collectionView is scrolled to a boundary. eg. the bottom.
	/// This is useful to enable loading more data when scrolling to bottom
	func onReachedBoundary(_ onReachedBoundary: @escaping OnReachedBoundaryCallback) -> Self
	{
		var this = self
		this.onReachedBoundaryCallback = onReachedBoundary
		return this
	}

	/// Set whether to show scroll indicators
	func scrollIndicatorsEnabled(horizontal: Bool = true, vertical: Bool = true) -> Self
	{
		var this = self
		this.horizontalScrollIndicatorEnabled = horizontal
		this.verticalScrollIndicatorEnabled = vertical
		return this
	}

	/// Set the content insets
	func contentInsets(_ insets: UIEdgeInsets) -> Self
	{
		var this = self
		this.contentInsets = insets
		return this
	}

	/// Set a closure that is called when the collectionView is pulled to refresh
	func onPullToRefresh(_ callback: ((_ endRefreshing: @escaping (() -> Void)) -> Void)?) -> Self
	{
		var this = self
		this.onPullToRefresh = callback
		return this
	}

	/// Set whether the ASCollectionView should always allow bounce vertically
	func alwaysBounceVertical(_ alwaysBounce: Bool = true) -> Self
	{
		var this = self
		this.alwaysBounceVertical = alwaysBounce
		return this
	}

	/// Set whether the ASCollectionView should always allow bounce horizontally
	func alwaysBounceHorizontal(_ alwaysBounce: Bool = true) -> Self
	{
		var this = self
		this.alwaysBounceHorizontal = alwaysBounce
		return this
	}

	/// Set an initial scroll position for the ASCollectionView
	func initialScrollPosition(_ position: ASCollectionViewScrollPosition?) -> Self
	{
		var this = self
		this.initialScrollPosition = position
		return this
	}

	/// Set whether the ASCollectionView should animate on data refresh
	func animateOnDataRefresh(_ animate: Bool = true) -> Self
	{
		var this = self
		this.animateOnDataRefresh = animate
		return this
	}

	/// Set whether the ASCollectionView should attempt to maintain scroll position on orientation change, default is true
	func shouldAttemptToMaintainScrollPositionOnOrientationChange(maintainPosition: Bool) -> Self
	{
		var this = self
		this.maintainScrollPositionOnOrientationChange = true
		return this
	}
}

// MARK: PUBLIC layout modifier functions

@available(iOS 13.0, *)
public extension ASCollectionView
{
	func layout(_ layout: Layout) -> Self
	{
		var this = self
		this.layout = layout
		return this
	}

	func layout(
		scrollDirection: UICollectionView.ScrollDirection = .vertical,
		interSectionSpacing: CGFloat = 10,
		layoutPerSection: @escaping CompositionalLayout<SectionID>) -> Self
	{
		var this = self
		this.layout = Layout(
			scrollDirection: scrollDirection,
			interSectionSpacing: interSectionSpacing,
			layoutPerSection: layoutPerSection)
		return this
	}

	func layout(
		scrollDirection: UICollectionView.ScrollDirection = .vertical,
		interSectionSpacing: CGFloat = 10,
		layout: @escaping CompositionalLayoutIgnoringSections) -> Self
	{
		var this = self
		this.layout = Layout(
			scrollDirection: scrollDirection,
			interSectionSpacing: interSectionSpacing,
			layout: layout)
		return this
	}

	func layout(customLayout: @escaping (() -> UICollectionViewLayout)) -> Self
	{
		var this = self
		this.layout = Layout(customLayout: customLayout)
		return this
	}

	func layout<LayoutClass: UICollectionViewLayout>(createCustomLayout: @escaping (() -> LayoutClass), configureCustomLayout: @escaping ((LayoutClass) -> Void)) -> Self
	{
		var this = self
		this.layout = Layout(createCustomLayout: createCustomLayout, configureCustomLayout: configureCustomLayout)
		return this
	}
}
