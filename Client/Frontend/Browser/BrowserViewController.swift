/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Photos
import UIKit
import WebKit
import Shared
import Storage
import SnapKit
import XCGLogger
import Alamofire

private let log = XCGLogger.defaultInstance()

private let OKString = NSLocalizedString("OK", comment: "OK button")
private let CancelString = NSLocalizedString("Cancel", comment: "Cancel button")

private let KVOLoading = "loading"
private let KVOEstimatedProgress = "estimatedProgress"
private let KVOURL = "URL"
private let KVOCanGoBack = "canGoBack"
private let KVOCanGoForward = "canGoForward"

private struct BrowserViewControllerUX {
    private static let BackgroundColor = UIConstants.AppBackgroundColor
    private static let ShowHeaderTapAreaHeight: CGFloat = 32
    private static let BookmarkStarAnimationDuration: Double = 0.5
    private static let BookmarkStarAnimationOffset: CGFloat = 80
}

class BrowserViewController: UIViewController {

    private var urlBar: URLBarView!
    private var readerModeBar: ReaderModeBarView?
    private var statusBarOverlay: UIView!
    private var toolbar: BrowserToolbar?
    private var homePanelController: HomePanelViewController?
    private var searchController: SearchViewController?
    private var webViewContainer: UIView!
    private let uriFixup = URIFixup()
    private var screenshotHelper: ScreenshotHelper!
    private var homePanelIsInline = false
    private var searchLoader: SearchLoader!
    private let snackBars = UIView()
    private let auralProgress = AuralProgressBar()

    // location label actions
    private var pasteGoAction: AccessibleAction!
    private var pasteAction: AccessibleAction!
    private var copyAddressAction: AccessibleAction!

    private weak var tabTrayController: TabTrayController!

    private let profile: Profile
    private let tabManager: TabManager

    // These views wrap the urlbar and toolbar to provide background effects on them
    private var header: UIView!
    private var footer: UIView!
    private var footerBackground: UIView!
    private var topTouchArea: UIButton!

    private var scrollController = BrowserScrollingController()

    private var keyboardState: KeyboardState?

    let WhiteListedUrls = ["\\/\\/itunes\\.apple\\.com\\/"]

    // Tracking navigation items to record history types.
    // TODO: weak references?
    var ignoredNavigation = Set<WKNavigation>()
    var typedNavigation = [WKNavigation: VisitType]()
    var navigationToolbar: BrowserToolbarProtocol {
        return toolbar ?? urlBar
    }

    init(profile: Profile, tabManager: TabManager) {
        self.profile = profile
        self.tabManager = tabManager
        super.init(nibName: nil, bundle: nil)
        didInit()
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func supportedInterfaceOrientations() -> Int {
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            return Int(UIInterfaceOrientationMask.AllButUpsideDown.rawValue)
        } else {
            return Int(UIInterfaceOrientationMask.All.rawValue)
        }
    }

    private func didInit() {
        screenshotHelper = BrowserScreenshotHelper(controller: self)
        tabManager.addDelegate(self)
        tabManager.addNavigationDelegate(self)
    }

    override func preferredStatusBarStyle() -> UIStatusBarStyle {
        if header == nil {
            return UIStatusBarStyle.LightContent
        }
        if header.transform.ty == 0 {
            return UIStatusBarStyle.LightContent
        }
        return UIStatusBarStyle.Default
    }

    func shouldShowToolbarForTraitCollection(previousTraitCollection: UITraitCollection) -> Bool {
        return previousTraitCollection.verticalSizeClass != .Compact &&
               previousTraitCollection.horizontalSizeClass != .Regular
    }

    private func updateToolbarStateForTraitCollection(newCollection: UITraitCollection) {
        let showToolbar = shouldShowToolbarForTraitCollection(newCollection)

        urlBar.setShowToolbar(!showToolbar)
        toolbar?.removeFromSuperview()
        toolbar?.browserToolbarDelegate = nil
        footerBackground?.removeFromSuperview()
        footerBackground = nil
        toolbar = nil

        if showToolbar {
            toolbar = BrowserToolbar()
            toolbar?.browserToolbarDelegate = self
            footerBackground = wrapInEffect(toolbar!, parent: footer)
        }

        view.setNeedsUpdateConstraints()
        if let home = homePanelController {
            home.view.setNeedsUpdateConstraints()
        }

        if let tab = tabManager.selectedTab,
               webView = tab.webView {
            navigationToolbar.updateBackStatus(webView.canGoBack)
            navigationToolbar.updateForwardStatus(webView.canGoForward)
            navigationToolbar.updateReloadStatus(tab.loading ?? false)
        }
    }

    override func willTransitionToTraitCollection(newCollection: UITraitCollection, withTransitionCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        super.willTransitionToTraitCollection(newCollection, withTransitionCoordinator: coordinator)
        updateToolbarStateForTraitCollection(newCollection)

        // WKWebView looks like it has a bug where it doesn't invalidate it's visible area when the user
        // performs a device rotation. Since scrolling calls
        // _updateVisibleContentRects (https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/API/Cocoa/WKWebView.mm#L1430)
        // this method nudges the web view's scroll view by a single pixel to force it to invalidate.
        if let scrollView = self.tabManager.selectedTab?.webView?.scrollView {
            let contentOffset = scrollView.contentOffset
            coordinator.animateAlongsideTransition({ context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y + 1), animated: true)
                self.scrollController.showToolbars(animated: false)
            }, completion: { context in
                scrollView.setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y), animated: false)
            })
        }
    }

    func SELstatusBarFrameWillChange(notification: NSNotification) {
        if let statusBarFrame = notification.userInfo![UIApplicationStatusBarFrameUserInfoKey] as? NSValue {
            scrollController.showToolbars(animated: false)
            self.view.setNeedsUpdateConstraints()
        }
    }

    func SELtappedTopArea() {
        scrollController.showToolbars(animated: true)
    }

    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillChangeStatusBarFrameNotification, object: nil)
        NSNotificationCenter.defaultCenter().removeObserver(self, name: BookmarkStatusChangedNotification, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "SELstatusBarFrameWillChange:", name: UIApplicationWillChangeStatusBarFrameNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "SELBookmarkStatusDidChange:", name: BookmarkStatusChangedNotification, object: nil)
        KeyboardHelper.defaultHelper.addDelegate(self)

        webViewContainer = UIView()
        view.addSubview(webViewContainer)

        // Temporary work around for covering the non-clipped web view content
        statusBarOverlay = UIView()
        statusBarOverlay.backgroundColor = BrowserViewControllerUX.BackgroundColor
        view.addSubview(statusBarOverlay)

        topTouchArea = UIButton()
        topTouchArea.addTarget(self, action: "SELtappedTopArea", forControlEvents: UIControlEvents.TouchUpInside)
        view.addSubview(topTouchArea)

        // Setup the URL bar, wrapped in a view to get transparency effect
        urlBar = URLBarView()
        urlBar.setTranslatesAutoresizingMaskIntoConstraints(false)
        urlBar.delegate = self
        urlBar.browserToolbarDelegate = self
        header = wrapInEffect(urlBar, parent: view, backgroundColor: nil)

        // UIAccessibilityCustomAction subclass holding an AccessibleAction instance does not work, thus unable to generate AccessibleActions and UIAccessibilityCustomActions "on-demand" and need to make them "persistent" e.g. by being stored in BVC
        pasteGoAction = AccessibleAction(name: NSLocalizedString("Paste & Go", comment: "Paste the URL into the location bar and visit"), handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                self.urlBar(self.urlBar, didSubmitText: pasteboardContents)
                return true
            }
            return false
        })
        pasteAction = AccessibleAction(name: NSLocalizedString("Paste", comment: "Paste the URL into the location bar"), handler: { () -> Bool in
            if let pasteboardContents = UIPasteboard.generalPasteboard().string {
                self.urlBar.updateURLBarText(pasteboardContents)
                return true
            }
            return false
        })
        copyAddressAction = AccessibleAction(name: NSLocalizedString("Copy Address", comment: "Copy the URL from the location bar"), handler: { () -> Bool in
            if let urlString = self.urlBar.currentURL?.absoluteString {
                UIPasteboard.generalPasteboard().string = urlString
            }
            return true
        })


        searchLoader = SearchLoader(history: profile.history, urlBar: urlBar)

        footer = UIView()
        self.view.addSubview(footer)
        footer.addSubview(snackBars)
        snackBars.backgroundColor = UIColor.clearColor()

        scrollController.urlBar = urlBar
        scrollController.header = header
        scrollController.footer = footer

        self.updateToolbarStateForTraitCollection(self.traitCollection)

    }

    func loadQueuedTabs() {
        log.debug("Loading queued tabs.")

        // This assumes that the DB returns rows in some kind of sane order.
        // It does in practice, so WFM.
        self.profile.queue.getQueuedTabs() >>== { c in
            log.debug("Queue. Count: \(c.count).")
            if c.count > 0 {
                var urls = [NSURL]()
                for (let r) in c {
                    if let url = r?.url.asURL {
                        log.debug("Queuing \(url).")
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    dispatch_async(dispatch_get_main_queue()) {
                        self.tabManager.addTabsForURLs(urls, zombie: false)
                    }
                }
            }

            // Clear *after* making an attempt to open. We're making a bet that
            // it's better to run the risk of perhaps opening twice on a crash,
            // rather than losing data.
            self.profile.queue.clearQueuedTabs()
        }
    }

    func startTrackingAccessibilityStatus() {
        NSNotificationCenter.defaultCenter().addObserverForName(UIAccessibilityVoiceOverStatusChanged, object: nil, queue: nil) { (notification) -> Void in
            self.auralProgress.hidden = !UIAccessibilityIsVoiceOverRunning()
        }
        auralProgress.hidden = !UIAccessibilityIsVoiceOverRunning()
    }

    func stopTrackingAccessibilityStatus() {
        NSNotificationCenter.defaultCenter().removeObserver(self, name: UIAccessibilityVoiceOverStatusChanged, object: nil)
        auralProgress.hidden = true
    }

    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)

        // On iPhone, if we are about to show the On-Boarding, blank out the browser so that it does
        // not flash before we present. This change of alpha also participates in the animation when
        // the intro view is dismissed.
        if UIDevice.currentDevice().userInterfaceIdiom == .Phone {
            self.view.alpha = (profile.prefs.intForKey(IntroViewControllerSeenProfileKey) != nil) ? 1.0 : 0.0
        }

        if tabManager.count == 0 && !AppConstants.IsRunningTest {
            // If we previously crashed, ask the user if they want to restore their tabs
            if FXCrashDetector.sharedDetector().hasCrashed() {
                let crashData = FXCrashDetector.sharedDetector().crashData as FXCrashDetectorData
                crashData.clearPreviousCrash()
                let alertView = UIAlertView(
                    title: CrashPromptMessaging.CrashPromptTitle,
                    message: CrashPromptMessaging.CrashPromptDescription,
                    delegate: self,
                    cancelButtonTitle: CrashPromptMessaging.CrashPromptNegative,
                    otherButtonTitles: CrashPromptMessaging.CrashPromptAffirmative)
                alertView.show()
            } else {
                tabManager.restoreTabs()
            }
        }

        // If restoring tabs failed, was disabled, there was nothing to restore, or we're running tests,
        // create an initial about:home tab.
        if tabManager.count == 0 {
            let tab = tabManager.addTab()
            tabManager.selectTab(tab)
        }
    }

    override func viewDidAppear(animated: Bool) {
        startTrackingAccessibilityStatus()
        presentIntroViewController()
        super.viewDidAppear(animated)
    }

    override func viewDidDisappear(animated: Bool) {
        stopTrackingAccessibilityStatus()
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()

        statusBarOverlay.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)
            make.height.equalTo(UIApplication.sharedApplication().statusBarFrame.height)
            make.bottom.equalTo(header.snp_top)
        }

        topTouchArea.snp_remakeConstraints { make in
            make.top.left.right.equalTo(self.view)
            make.height.equalTo(BrowserViewControllerUX.ShowHeaderTapAreaHeight)
        }

        urlBar.snp_remakeConstraints { make in
            make.edges.equalTo(self.header)
        }

        header.snp_remakeConstraints { make in
            let topLayoutGuide = self.topLayoutGuide as! UIView
            scrollController.headerTopConstraint = make.top.equalTo(topLayoutGuide.snp_bottom).constraint
            make.height.equalTo(UIConstants.ToolbarHeight)
            make.left.right.equalTo(self.view)
        }
        header.setNeedsUpdateConstraints()

        readerModeBar?.snp_remakeConstraints { make in
            make.top.equalTo(self.header.snp_bottom).constraint
            make.height.equalTo(UIConstants.ToolbarHeight)
            make.leading.trailing.equalTo(self.view)
        }

        webViewContainer.snp_remakeConstraints { make in
            make.left.right.equalTo(self.view)

            if let readerModeBarBottom = readerModeBar?.snp_bottom {
                make.top.equalTo(readerModeBarBottom)
            } else {
                make.top.equalTo(self.header.snp_bottom)
            }

            if let toolbar = self.toolbar {
                make.bottom.equalTo(toolbar.snp_top)
            } else {
                make.bottom.equalTo(self.view)
            }
        }

        // Setup the bottom toolbar
        toolbar?.snp_remakeConstraints { make in
            make.edges.equalTo(self.footerBackground!)
            make.height.equalTo(UIConstants.ToolbarHeight)
        }

        footer.snp_remakeConstraints { make in
            scrollController.footerBottomConstraint = make.bottom.equalTo(self.view.snp_bottom).constraint
            make.top.equalTo(self.snackBars.snp_top)
            make.leading.trailing.equalTo(self.view)
        }

        adjustFooterSize(top: nil)
        footerBackground?.snp_remakeConstraints { make in
            make.bottom.left.right.equalTo(self.footer)
            make.height.equalTo(UIConstants.ToolbarHeight)
        }
        urlBar.setNeedsUpdateConstraints()

        // Remake constraints even if we're already showing the home controller.
        // The home controller may change sizes if we tap the URL bar while on about:home.
        homePanelController?.view.snp_remakeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.equalTo(self.view)
            if self.homePanelIsInline {
                make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            } else {
                make.bottom.equalTo(self.view.snp_bottom)
            }
        }
    }

    private func wrapInEffect(view: UIView, parent: UIView) -> UIView {
        return self.wrapInEffect(view, parent: parent, backgroundColor: UIColor.clearColor())
    }

    private func wrapInEffect(view: UIView, parent: UIView, backgroundColor: UIColor?) -> UIView {
        let effect = UIVisualEffectView(effect: UIBlurEffect(style: UIBlurEffectStyle.ExtraLight))
        effect.setTranslatesAutoresizingMaskIntoConstraints(false)
        if let background = backgroundColor {
            view.backgroundColor = backgroundColor
        }
        effect.addSubview(view)

        parent.addSubview(effect)
        return effect
    }

    private func showHomePanelController(#inline: Bool) {
        homePanelIsInline = inline

        if homePanelController == nil {
            homePanelController = HomePanelViewController()
            homePanelController!.profile = profile
            homePanelController!.delegate = self
            homePanelController!.url = tabManager.selectedTab?.displayURL
            homePanelController!.view.alpha = 0
            view.addSubview(homePanelController!.view)

            addChildViewController(homePanelController!)
        }

        var panelNumber = tabManager.selectedTab?.url?.fragment
        var numberArray = panelNumber?.componentsSeparatedByString("=")
        homePanelController?.selectedButtonIndex = numberArray?.last?.toInt() ?? 0

        // We have to run this animation, even if the view is already showing because there may be a hide animation running
        // and we want to be sure to override its results.
        UIView.animateWithDuration(0.2, animations: { () -> Void in
            self.homePanelController!.view.alpha = 1
        }, completion: { finished in
            if finished {
                self.webViewContainer.accessibilityElementsHidden = true
                self.stopTrackingAccessibilityStatus()
                UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            }
        })
        toolbar?.hidden = !inline
        view.setNeedsUpdateConstraints()
    }

    private func hideHomePanelController() {
        if let controller = homePanelController {
            UIView.animateWithDuration(0.2, delay: 0, options: .BeginFromCurrentState, animations: { () -> Void in
                controller.view.alpha = 0
            }, completion: { finished in
                if finished {
                    controller.view.removeFromSuperview()
                    controller.removeFromParentViewController()
                    self.homePanelController = nil
                    self.webViewContainer.accessibilityElementsHidden = false
                    self.toolbar?.hidden = false
                    self.startTrackingAccessibilityStatus()
                    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)

                    // Refresh the reading view toolbar since the article record may have changed
                    if let readerMode = self.tabManager.selectedTab?.getHelper(name: ReaderMode.name()) as? ReaderMode where readerMode.state == .Active {
                        self.showReaderModeBar(animated: false)
                    }
                }
            })
        }
    }

    private func updateInContentHomePanel(url: NSURL?) {
        if !urlBar.isEditing {
            if AboutUtils.isAboutHomeURL(url){
                showHomePanelController(inline: (tabManager.selectedTab?.canGoForward ?? false || tabManager.selectedTab?.canGoBack ?? false))
            } else {
                hideHomePanelController()
            }
        }
    }

    private func showSearchController() {
        if searchController != nil {
            return
        }

        urlBar.locationView.inputMode = .Search

        searchController = SearchViewController()
        searchController!.searchEngines = profile.searchEngines
        searchController!.searchDelegate = self
        searchController!.profile = self.profile

        searchLoader.addListener(searchController!)

        view.addSubview(searchController!.view)
        searchController!.view.snp_makeConstraints { make in
            make.top.equalTo(self.urlBar.snp_bottom)
            make.left.right.bottom.equalTo(self.view)
            return
        }

        homePanelController?.view?.hidden = true

        addChildViewController(searchController!)
    }

    private func hideSearchController() {
        if let searchController = searchController {
            searchController.view.removeFromSuperview()
            searchController.removeFromParentViewController()
            self.searchController = nil
            urlBar.locationView.inputMode = .URL
            homePanelController?.view?.hidden = false
        }
    }

    private func finishEditingAndSubmit(var url: NSURL, visitType: VisitType) {
        urlBar.currentURL = url
        urlBar.finishEditing()

        if let tab = tabManager.selectedTab,
           let nav = tab.loadRequest(NSURLRequest(URL: url)) {
            self.recordNavigationInTab(tab, navigation: nav, visitType: visitType)
        }
    }

    func addBookmark(url: String, title: String?) {
        let shareItem = ShareItem(url: url, title: title, favicon: nil)
        profile.bookmarks.shareItem(shareItem)

        animateBookmarkStar()

        // Dispatch to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue()) { _ in
            self.toolbar?.updateBookmarkStatus(true)
            self.urlBar.updateBookmarkStatus(true)
        }
    }

    private func animateBookmarkStar() {
        let offset: CGFloat
        let button: UIButton!

        if let toolbar: BrowserToolbar = self.toolbar {
            offset = BrowserViewControllerUX.BookmarkStarAnimationOffset * -1
            button = toolbar.bookmarkButton
        } else {
            offset = BrowserViewControllerUX.BookmarkStarAnimationOffset
            button = self.urlBar.bookmarkButton
        }

        let offToolbar = CGAffineTransformMakeTranslation(0, offset)

        UIView.animateWithDuration(BrowserViewControllerUX.BookmarkStarAnimationDuration, delay: 0.0, usingSpringWithDamping: 0.6, initialSpringVelocity: 2.0, options: nil, animations: { () -> Void in
            button.transform = offToolbar
            var rotation = CABasicAnimation(keyPath: "transform.rotation")
            rotation.toValue = CGFloat(M_PI * 2.0)
            rotation.cumulative = true
            rotation.duration = BrowserViewControllerUX.BookmarkStarAnimationDuration + 0.075
            rotation.repeatCount = 1.0
            rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.70 ,0.18 ,1.00)
            button.imageView?.layer.addAnimation(rotation, forKey: "rotateStar")
        }, completion: { finished in
            UIView.animateWithDuration(BrowserViewControllerUX.BookmarkStarAnimationDuration, delay: 0.15, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: nil, animations: { () -> Void in
                button.transform = CGAffineTransformIdentity
            }, completion: nil)
        })
    }

    private func removeBookmark(url: String) {
        profile.bookmarks.removeByURL(url).uponQueue(dispatch_get_main_queue()) { res in
            if res.isSuccess {
                self.toolbar?.updateBookmarkStatus(false)
                self.urlBar.updateBookmarkStatus(false)
            }
        }
    }

    func SELBookmarkStatusDidChange(notification: NSNotification) {
        if let bookmark = notification.object as? BookmarkItem {
            if bookmark.url == urlBar.currentURL?.absoluteString {
                if let userInfo = notification.userInfo as? Dictionary<String, Bool>{
                    if let added = userInfo["added"]{
                        self.toolbar?.updateBookmarkStatus(added)
                        self.urlBar.updateBookmarkStatus(added)
                    }
                }
            }
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if urlBar.canCancel {
            urlBar.SELdidClickCancel()
            return true
        } else if let selectedTab = tabManager.selectedTab where selectedTab.canGoBack {
            selectedTab.goBack()
            return true
        }
        return false
    }

    override func observeValueForKeyPath(keyPath: String, ofObject object: AnyObject, change: [NSObject: AnyObject], context: UnsafeMutablePointer<Void>) {
        let webView = object as! WKWebView
        if webView !== tabManager.selectedTab?.webView {
            return
        }

        switch keyPath {
        case KVOEstimatedProgress:
            let progress = change[NSKeyValueChangeNewKey] as! Float
            urlBar.updateProgressBar(progress)
            // when loading is stopped, KVOLoading is fired first, and only then KVOEstimatedProgress with progress 1.0 which would leave the progress bar running
            if progress != 1.0 || tabManager.selectedTab?.loading ?? false {
                auralProgress.progress = Double(progress)
            }
        case KVOLoading:
            let loading = change[NSKeyValueChangeNewKey] as! Bool
            toolbar?.updateReloadStatus(loading)
            urlBar.updateReloadStatus(loading)
            auralProgress.progress = loading ? 0 : nil
        case KVOURL:
            if let tab = tabManager.selectedTab where tab.webView === webView {
                updateURLBarDisplayURL(tab)

                scrollController.showToolbars(animated: false)

                if let url = tab.url {
                    if ReaderModeUtils.isReaderModeURL(url) {
                        showReaderModeBar(animated: false)
                    } else {
                        hideReaderModeBar(animated: false)
                    }
                }
                updateInContentHomePanel(tab.url)
            }
        case KVOCanGoBack:
            let canGoBack = change[NSKeyValueChangeNewKey] as! Bool
            navigationToolbar.updateBackStatus(canGoBack)
        case KVOCanGoForward:
            let canGoForward = change[NSKeyValueChangeNewKey] as! Bool
            navigationToolbar.updateForwardStatus(canGoForward)
        default:
            assertionFailure("Unhandled KVO key: \(keyPath)")
        }
    }

    private func isWhitelistedUrl(url: NSURL) -> Bool {
        for entry in WhiteListedUrls {
            if let match = url.absoluteString!.rangeOfString(entry, options: .RegularExpressionSearch) {
                return UIApplication.sharedApplication().canOpenURL(url)
            }
        }
        return false
    }

    /// Updates the URL bar text and button states.
    /// Call this whenever the page URL changes.
    private func updateURLBarDisplayURL(tab: Browser) {
        urlBar.currentURL = tab.displayURL

        let isPage = (tab.displayURL != nil) ? isWebPage(tab.displayURL!) : false
        navigationToolbar.updatePageStatus(isWebPage: isPage)

        if let url = tab.displayURL?.absoluteString {
            profile.bookmarks.isBookmarked(url, success: { bookmarked in
                self.navigationToolbar.updateBookmarkStatus(bookmarked)
            }, failure: { err in
                log.error("Error getting bookmark status: \(err).")
            })
        }
    }

    func openURLInNewTab(url: NSURL) {
        let tab = tabManager.addTab(request: NSURLRequest(URL: url))
        tabManager.selectTab(tab)
    }
}

/**
 * History visit management.
 * TODO: this should be expanded to track various visit types; see Bug 1166084.
 */
extension BrowserViewController {
    func ignoreNavigationInTab(tab: Browser, navigation: WKNavigation) {
        self.ignoredNavigation.insert(navigation)
    }

    func recordNavigationInTab(tab: Browser, navigation: WKNavigation, visitType: VisitType) {
        self.typedNavigation[navigation] = visitType
    }

    /**
     * Untrack and do the right thing.
     */
    func getVisitTypeForTab(tab: Browser, navigation: WKNavigation?) -> VisitType? {
        if let navigation = navigation {
            if let ignored = self.ignoredNavigation.remove(navigation) {
                return nil
            }
            return self.typedNavigation.removeValueForKey(navigation) ?? VisitType.Link
        } else {
            // See https://github.com/WebKit/webkit/blob/master/Source/WebKit2/UIProcess/Cocoa/NavigationState.mm#L390
            return VisitType.Link
        }
    }
}

extension BrowserViewController: URLBarDelegate {
    func urlBarDidPressReload(urlBar: URLBarView) {
        tabManager.selectedTab?.reload()
    }

    func urlBarDidPressStop(urlBar: URLBarView) {
        tabManager.selectedTab?.stop()
    }

    func urlBarDidPressTabs(urlBar: URLBarView) {
        let tabTrayController = TabTrayController()
        tabTrayController.profile = profile
        tabTrayController.tabManager = tabManager
        tabTrayController.transitioningDelegate = self
        tabTrayController.modalPresentationStyle = .Custom

        if let tab = tabManager.selectedTab {
            tab.screenshot = screenshotHelper.takeScreenshot(tab, aspectRatio: 0, quality: 1)
        }

        presentViewController(tabTrayController, animated: true, completion: nil)
        self.tabTrayController = tabTrayController
    }

    func dismissTabTrayController(#animated: Bool, completion: () -> Void) {
        if let tabTrayController = tabTrayController {
            tabTrayController.dismissViewControllerAnimated(animated) {
                completion()
                self.tabTrayController = nil
            }
        }
    }

    func urlBarDidPressReaderMode(urlBar: URLBarView) {
        if let tab = tabManager.selectedTab {
            if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                switch readerMode.state {
                case .Available:
                    enableReaderMode()
                case .Active:
                    disableReaderMode()
                case .Unavailable:
                    break
                }
            }
        }
    }

    func urlBarDidLongPressReaderMode(urlBar: URLBarView) -> Bool {
        if let tab = tabManager.selectedTab,
               url = tab.displayURL,
               absoluteString = url.absoluteString,
               result = profile.readingList?.createRecordWithURL(absoluteString, title: tab.title ?? "", addedBy: UIDevice.currentDevice().name)
        {
            switch result {
            case .Success:
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Added page to Reading List", comment: "Accessibility message e.g. spoken by VoiceOver after the current page gets added to the Reading List using the Reader View button, e.g. by long-pressing it or by its accessibility custom action."))
                // TODO: https://bugzilla.mozilla.org/show_bug.cgi?id=1158503 provide some form of 'this has been added' visual feedback?
            case .Failure(let error):
                UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Could not add page to Reading List. Maybe it's already there?", comment: "Accessibility message e.g. spoken by VoiceOver after the user wanted to add current page to the Reading List and this was not done, likely because it already was in the Reading List, but perhaps also because of real failures."))
                log.error("readingList.createRecordWithURL(url: \"\(absoluteString)\", ...) failed with error: \(error)")
            }
            return true
        }
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, NSLocalizedString("Could not add page to Reading list", comment: "Accessibility message e.g. spoken by VoiceOver after adding current webpage to the Reading List failed."))
        return false
    }

    func locationActionsForURLBar(urlBar: URLBarView) -> [AccessibleAction] {
        if UIPasteboard.generalPasteboard().string != nil {
            return [pasteGoAction, pasteAction, copyAddressAction]
        } else {
            return [copyAddressAction]
        }
    }

    func urlBarDidLongPressLocation(urlBar: URLBarView) {
        let longPressAlertController = UIAlertController(title: nil, message: nil, preferredStyle: .ActionSheet)

        for action in locationActionsForURLBar(urlBar) {
            longPressAlertController.addAction(action.alertAction(style: .Default))
        }

        let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: "Cancel alert view"), style: .Cancel, handler: { (alert: UIAlertAction!) -> Void in
        })
        longPressAlertController.addAction(cancelAction)

        if let popoverPresentationController = longPressAlertController.popoverPresentationController {
            popoverPresentationController.sourceView = urlBar
            popoverPresentationController.sourceRect = urlBar.frame
            popoverPresentationController.permittedArrowDirections = .Any
        }
        self.presentViewController(longPressAlertController, animated: true, completion: nil)
    }

    func urlBarDidPressScrollToTop(urlBar: URLBarView) {
        if let selectedTab = tabManager.selectedTab {
            // Only scroll to top if we are not showing the home view controller
            if homePanelController == nil {
                selectedTab.webView?.scrollView.setContentOffset(CGPointZero, animated: true)
            }
        }
    }

    func urlBarLocationAccessibilityActions(urlBar: URLBarView) -> [UIAccessibilityCustomAction]? {
        return locationActionsForURLBar(urlBar).map { $0.accessibilityCustomAction }
    }

    func urlBar(urlBar: URLBarView, didEnterText text: String) {
        searchLoader.query = text

        if text.isEmpty {
            hideSearchController()
        } else {
            showSearchController()
            searchController!.searchQuery = text
        }
    }

    func urlBar(urlBar: URLBarView, didSubmitText text: String) {
        var url = uriFixup.getURL(text)

        // If we can't make a valid URL, do a search query.
        if url == nil {
            url = profile.searchEngines.defaultEngine.searchURLForQuery(text)
        }

        // If we still don't have a valid URL, something is broken. Give up.
        if url == nil {
            log.error("Error handling URL entry: \"\(text)\".")
            return
        }

        finishEditingAndSubmit(url!, visitType: VisitType.Typed)
    }

    func urlBarDidBeginEditing(urlBar: URLBarView) {
        // Pass the edit message along if we are already showing the home panel
        if let homePanelController = self.homePanelController where homePanelController.view.alpha == 1 {
            homePanelController.endEditing(nil)
        } else {
            showHomePanelController(inline: false)
        }
    }

    func urlBarDidEndEditing(urlBar: URLBarView) {
        hideSearchController()
        updateInContentHomePanel(tabManager.selectedTab?.url)
    }
}

extension BrowserViewController: BrowserToolbarDelegate {
    func browserToolbarDidPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goBack()
    }

    func browserToolbarDidLongPressBack(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
// See 1159373 - Disable long press back/forward for backforward list
//        let controller = BackForwardListViewController()
//        controller.listData = tabManager.selectedTab?.backList
//        controller.tabManager = tabManager
//        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressReload(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.reload()
    }

    func browserToolbarDidPressStop(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.stop()
    }

    func browserToolbarDidPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        tabManager.selectedTab?.goForward()
    }

    func browserToolbarDidLongPressForward(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
// See 1159373 - Disable long press back/forward for backforward list
//        let controller = BackForwardListViewController()
//        controller.listData = tabManager.selectedTab?.forwardList
//        controller.tabManager = tabManager
//        presentViewController(controller, animated: true, completion: nil)
    }

    func browserToolbarDidPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        if let tab = tabManager.selectedTab,
           let url = tab.displayURL?.absoluteString {
            profile.bookmarks.isBookmarked(url,
                success: { isBookmarked in
                    if isBookmarked {
                        self.removeBookmark(url)
                    } else {
                        self.addBookmark(url, title: tab.title)
                    }
                },
                failure: { err in
                    log.error("Bookmark error: \(err).")
                }
            )
        } else {
            log.error("Bookmark error: No tab is selected, or no URL in tab.")
        }
    }

    func browserToolbarDidLongPressBookmark(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
    }

    func browserToolbarDidPressShare(browserToolbar: BrowserToolbarProtocol, button: UIButton) {
        if let selected = tabManager.selectedTab {
            if let url = selected.displayURL {
                var activityViewController = UIActivityViewController(activityItems: [selected.title ?? url.absoluteString!, url], applicationActivities: nil)
                // Hide 'Add to Reading List' which currently uses Safari
                activityViewController.excludedActivityTypes = [UIActivityTypeAddToReadingList]
                if let popoverPresentationController = activityViewController.popoverPresentationController {
                    // Using the button for the sourceView here results in this not showing on iPads.
                    popoverPresentationController.sourceView = toolbar ?? urlBar
                    popoverPresentationController.sourceRect = button.frame ?? button.frame
                    popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirection.Up
                }
                presentViewController(activityViewController, animated: true, completion: nil)
            }
        }
    }
}

extension BrowserViewController: BrowserDelegate {

    func browser(browser: Browser, didCreateWebView webView: WKWebView) {
        webViewContainer.insertSubview(webView, atIndex: 0)
        webView.snp_makeConstraints { make in
            make.edges.equalTo(self.webViewContainer)
        }

        // Observers that live as long as the tab. Make sure these are all cleared
        // in willDeleteWebView below!
        webView.addObserver(self, forKeyPath: KVOEstimatedProgress, options: .New, context: nil)
        webView.addObserver(self, forKeyPath: KVOLoading, options: .New, context: nil)
        webView.addObserver(self, forKeyPath: KVOURL, options: .New, context: nil)
        webView.addObserver(self, forKeyPath: KVOCanGoBack, options: .New, context: nil)
        webView.addObserver(self, forKeyPath: KVOCanGoForward, options: .New, context: nil)

        webView.UIDelegate = self

        let readerMode = ReaderMode(browser: browser)
        readerMode.delegate = self
        browser.addHelper(readerMode, name: ReaderMode.name())

        let favicons = FaviconManager(browser: browser, profile: profile)
        browser.addHelper(favicons, name: FaviconManager.name())

        // Temporarily disable password support until the new code lands
        let logins = LoginsHelper(browser: browser, profile: profile)
        browser.addHelper(logins, name: LoginsHelper.name())

        let contextMenuHelper = ContextMenuHelper(browser: browser)
        contextMenuHelper.delegate = self
        browser.addHelper(contextMenuHelper, name: ContextMenuHelper.name())

        let errorHelper = ErrorPageHelper()
        browser.addHelper(errorHelper, name: ErrorPageHelper.name())
    }

    func browser(browser: Browser, willDeleteWebView webView: WKWebView) {
        webView.removeObserver(self, forKeyPath: KVOEstimatedProgress)
        webView.removeObserver(self, forKeyPath: KVOLoading)
        webView.removeObserver(self, forKeyPath: KVOURL)
        webView.removeObserver(self, forKeyPath: KVOCanGoBack)
        webView.removeObserver(self, forKeyPath: KVOCanGoForward)

        webView.UIDelegate = nil
        webView.scrollView.delegate = nil
        webView.removeFromSuperview()
    }

    private func findSnackbar(barToFind: SnackBar) -> Int? {
        let bars = snackBars.subviews
        for (index, bar) in enumerate(bars) {
            if bar === barToFind {
                return index
            }
        }
        return nil
    }

    private func adjustFooterSize(top: UIView? = nil) {
        snackBars.snp_remakeConstraints({ make in
            let bars = self.snackBars.subviews
            // if the keyboard is showing then ensure that the snackbars are positioned above it, otherwise position them above the toolbar/view bottom
            if let state = keyboardState {
                make.bottom.equalTo(-(state.height + 20))
            } else {
                make.bottom.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            }
            if traitCollection.horizontalSizeClass != .Regular {
                make.leading.trailing.equalTo(self.footer)
                self.snackBars.layer.borderWidth = 0
            } else {
                make.centerX.equalTo(self.footer)
                make.width.equalTo(SnackBarUX.MaxWidth)
                self.snackBars.layer.borderColor = UIConstants.BorderColor.CGColor
                self.snackBars.layer.borderWidth = 1
            }

            if bars.count > 0 {
                let view = bars[bars.count-1] as! UIView
                make.top.equalTo(view.snp_top)
            } else {
                make.top.equalTo(self.toolbar?.snp_top ?? self.view.snp_bottom)
            }
        })
    }

    // This removes the bar from its superview and updates constraints appropriately
    private func finishRemovingBar(bar: SnackBar) {
        // If there was a bar above this one, we need to remake its constraints.
        if let index = findSnackbar(bar) {
            // If the bar being removed isn't on the top of the list
            let bars = snackBars.subviews
            if index < bars.count-1 {
                // Move the bar above this one
                var nextbar = bars[index+1] as! SnackBar
                nextbar.snp_updateConstraints { make in
                    // If this wasn't the bottom bar, attach to the bar below it
                    if index > 0 {
                        let bar = bars[index-1] as! SnackBar
                        nextbar.bottom = make.bottom.equalTo(bar.snp_top).constraint
                    } else {
                        // Otherwise, we attach it to the bottom of the snackbars
                        nextbar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).constraint
                    }
                }
            }
        }

        // Really remove the bar
        bar.removeFromSuperview()
    }

    private func finishAddingBar(bar: SnackBar) {
        snackBars.addSubview(bar)
        bar.snp_remakeConstraints({ make in
            // If there are already bars showing, add this on top of them
            let bars = self.snackBars.subviews

            // Add the bar on top of the stack
            // We're the new top bar in the stack, so make sure we ignore ourself
            if bars.count > 1 {
                let view = bars[bars.count - 2] as! UIView
                bar.bottom = make.bottom.equalTo(view.snp_top).offset(0).constraint
            } else {
                bar.bottom = make.bottom.equalTo(self.snackBars.snp_bottom).offset(0).constraint
            }
            make.leading.trailing.equalTo(self.snackBars)
        })
    }

    func showBar(bar: SnackBar, animated: Bool) {
        finishAddingBar(bar)
        adjustFooterSize(top: bar)

        bar.hide()
        view.layoutIfNeeded()
        UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
            bar.show()
            self.view.layoutIfNeeded()
        })
    }

    func removeBar(bar: SnackBar, animated: Bool) {
        let index = findSnackbar(bar)!
        UIView.animateWithDuration(animated ? 0.25 : 0, animations: { () -> Void in
            bar.hide()
            self.view.layoutIfNeeded()
        }) { success in
            // Really remove the bar
            self.finishRemovingBar(bar)

            // Adjust the footer size to only contain the bars
            self.adjustFooterSize()
        }
    }

    func removeAllBars() {
        let bars = snackBars.subviews
        for bar in bars {
            if let bar = bar as? SnackBar {
                bar.removeFromSuperview()
            }
        }
        self.adjustFooterSize()
    }

    func browser(browser: Browser, didAddSnackbar bar: SnackBar) {
        showBar(bar, animated: true)
    }

    func browser(browser: Browser, didRemoveSnackbar bar: SnackBar) {
        removeBar(bar, animated: true)
    }
}

extension BrowserViewController: HomePanelViewControllerDelegate {
    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectURL url: NSURL, visitType: VisitType) {
        finishEditingAndSubmit(url, visitType: visitType)
    }

    func homePanelViewController(homePanelViewController: HomePanelViewController, didSelectPanel panel: Int) {
        if AboutUtils.isAboutHomeURL(tabManager.selectedTab?.url) {
            tabManager.selectedTab?.webView?.evaluateJavaScript("history.replaceState({}, '', '#panel=\(panel)')", completionHandler: nil)
        }
    }

    func homePanelViewControllerDidRequestToCreateAccount(homePanelViewController: HomePanelViewController) {
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
    }

    func homePanelViewControllerDidRequestToSignIn(homePanelViewController: HomePanelViewController) {
        presentSignInViewController() // TODO UX Right now the flow for sign in and create account is the same
    }
}

extension BrowserViewController: SearchViewControllerDelegate {
    func searchViewController(searchViewController: SearchViewController, didSelectURL url: NSURL) {
        finishEditingAndSubmit(url, visitType: VisitType.Typed)
    }

    func presentSearchSettingsController() {

        let settingsNavigationController = SearchSettingsTableViewController()
        settingsNavigationController.model = self.profile.searchEngines

        let navController = UINavigationController(rootViewController: settingsNavigationController)

        self.presentViewController(navController, animated: true, completion: nil)
    }

    func searchViewControllerWillAppear(searchViewController: SearchViewController) {
        self.urlBar.locationView.editTextField.becomeFirstResponder()
    }
}

extension BrowserViewController: TabManagerDelegate {
    func tabManager(tabManager: TabManager, didSelectedTabChange selected: Browser?, previous: Browser?) {
        // Remove the old accessibilityLabel. Since this webview shouldn't be visible, it doesn't need it
        // and having multiple views with the same label confuses tests.
        if let wv = previous?.webView {
            wv.accessibilityLabel = nil
            wv.accessibilityElementsHidden = true
            wv.accessibilityIdentifier = nil
            // due to screwy handling within iOS, the scrollToTop handling does not work if there are
            // more than one scroll view in the view hierarchy
            // we therefore have to hide all the scrollViews that we are no actually interesting in interacting with
            // to ensure that scrollsToTop actually works
            wv.scrollView.hidden = true
        }

        if let tab = selected,
               webView = tab.webView {
            // if we have previously hidden this scrollview in order to make scrollsToTop work then
            // we should ensure that it is not hidden now that it is our foreground scrollView
            if webView.scrollView.hidden {
                webView.scrollView.hidden = false
            }

            updateURLBarDisplayURL(tab)

            scrollController.browser = selected
            webViewContainer.addSubview(webView)
            webView.accessibilityLabel = NSLocalizedString("Web content", comment: "Accessibility label for the main web content view")
            webView.accessibilityIdentifier = "contentView"
            webView.accessibilityElementsHidden = false

            if let url = webView.URL?.absoluteString {
                profile.bookmarks.isBookmarked(url, success: { bookmarked in
                    self.toolbar?.updateBookmarkStatus(bookmarked)
                    self.urlBar.updateBookmarkStatus(bookmarked)
                }, failure: { err in
                    log.error("Error getting bookmark status: \(err).")
                })
            } else {
                // The web view can go gray if it was zombified due to memory pressure.
                // When this happens, the URL is nil, so try restoring the page upon selection.
                webView.reload()
            }
        }

        removeAllBars()
        if let bars = selected?.bars {
            for bar in bars {
                showBar(bar, animated: true)
            }
        }

        navigationToolbar.updateReloadStatus(selected?.loading ?? false)

        let isPage = (selected?.displayURL != nil) ? isWebPage(selected!.displayURL!) : false
        navigationToolbar.updatePageStatus(isWebPage: isPage)

        self.urlBar.updateBackStatus(selected?.canGoBack ?? false)
        self.urlBar.updateForwardStatus(selected?.canGoForward ?? false)
        self.urlBar.updateProgressBar(Float(selected?.estimatedProgress ?? 0))

        if let readerMode = selected?.getHelper(name: ReaderMode.name()) as? ReaderMode {
            urlBar.updateReaderModeState(readerMode.state)
            if readerMode.state == .Active {
                showReaderModeBar(animated: false)
            } else {
                hideReaderModeBar(animated: false)
            }
        } else {
            urlBar.updateReaderModeState(ReaderModeState.Unavailable)
        }

        updateInContentHomePanel(selected?.url)
    }

    func tabManager(tabManager: TabManager, didCreateTab tab: Browser, restoring: Bool) {
    }

    func tabManager(tabManager: TabManager, didAddTab tab: Browser, atIndex: Int, restoring: Bool) {
        // If we are restoring tabs then we update the count once at the end
        if !restoring {
            urlBar.updateTabCount(tabManager.count)
        }
        tab.browserDelegate = self
    }

    func tabManager(tabManager: TabManager, didRemoveTab tab: Browser, atIndex: Int) {
        urlBar.updateTabCount(tabManager.count)
        // browserDelegate is a weak ref (and the tab's webView may not be destroyed yet)
        // so we don't expcitly unset it.
    }

    func tabManagerDidAddTabs(tabManager: TabManager) {
        urlBar.updateTabCount(tabManager.count)
    }

    func tabManagerDidRestoreTabs(tabManager: TabManager) {
        urlBar.updateTabCount(tabManager.count)
    }

    private func isWebPage(url: NSURL) -> Bool {
        let httpSchemes = ["http", "https"]

        if let scheme = url.scheme,
            index = find(httpSchemes, scheme) {
                return true
        }

        return false
    }
}

extension BrowserViewController: WKNavigationDelegate {
    func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if tabManager.selectedTab?.webView !== webView {
            return
        }

        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let url = webView.URL {
            if !ReaderModeUtils.isReaderModeURL(url) {
                urlBar.updateReaderModeState(ReaderModeState.Unavailable)
            }
        }
    }

    private func openExternal(url: NSURL, prompt: Bool = true) {
        if prompt {
            // Ask the user if it's okay to open the url with UIApplication.
            let alert = UIAlertController(
                title: String(format: NSLocalizedString("Opening %@", comment:"Opening an external URL"), url),
                message: NSLocalizedString("This will open in another application", comment: "Opening an external app"),
                preferredStyle: UIAlertControllerStyle.Alert
            )

            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: { (action: UIAlertAction!) in
            }))

            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment:"Alert OK Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                UIApplication.sharedApplication().openURL(url)
            }))

            presentViewController(alert, animated: true, completion: nil)
        } else {
            UIApplication.sharedApplication().openURL(url)
        }
    }

    private func callExternal(url: NSURL) {
        if let phoneNumber = url.resourceSpecifier?.stringByReplacingPercentEscapesUsingEncoding(NSUTF8StringEncoding) {
            let alert = UIAlertController(title: phoneNumber, message: nil, preferredStyle: UIAlertControllerStyle.Alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment:"Alert Cancel Button"), style: UIAlertActionStyle.Cancel, handler: nil))
            alert.addAction(UIAlertAction(title: NSLocalizedString("Call", comment:"Alert Call Button"), style: UIAlertActionStyle.Default, handler: { (action: UIAlertAction!) in
                UIApplication.sharedApplication().openURL(url)
            }))
            presentViewController(alert, animated: true, completion: nil)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationAction navigationAction: WKNavigationAction, decisionHandler: (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.URL {
            if let scheme = url.scheme {
                switch scheme {
                case "about", "http", "https":
                    if isWhitelistedUrl(url) {
                        // If the url is whitelisted, we open it without prompting.
                        openExternal(url, prompt: false)
                        decisionHandler(WKNavigationActionPolicy.Cancel)
                    } else {
                        decisionHandler(WKNavigationActionPolicy.Allow)
                    }
                case "tel":
                    callExternal(url)
                    decisionHandler(WKNavigationActionPolicy.Cancel)
                default:
                    if UIApplication.sharedApplication().canOpenURL(url) {
                        openExternal(url)
                    }
                    decisionHandler(WKNavigationActionPolicy.Cancel)
                }
            }
        } else {
            decisionHandler(WKNavigationActionPolicy.Cancel)
        }
    }

    func webView(webView: WKWebView,
        didReceiveAuthenticationChallenge challenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential!) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic || challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
                if let tab = tabManager[webView] {
                    let helper = tab.getHelper(name: LoginsHelper.name()) as! LoginsHelper
                    helper.handleAuthRequest(self, challenge: challenge).uponQueue(dispatch_get_main_queue()) { res in
                        if let credentials = res.successValue {
                            completionHandler(.UseCredential, credentials.credentials)
                        } else {
                            completionHandler(NSURLSessionAuthChallengeDisposition.CancelAuthenticationChallenge, nil)
                        }
                    }
                }
            } else {
                completionHandler(NSURLSessionAuthChallengeDisposition.PerformDefaultHandling, nil)
            }
    }

    func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {
        let tab: Browser! = tabManager[webView]

        tab.expireSnackbars()

        if let url = webView.URL where !ErrorPageHelper.isErrorPageURL(url) && !AboutUtils.isAboutHomeURL(url) {
            let notificationCenter = NSNotificationCenter.defaultCenter()
            var info = [NSObject: AnyObject]()
            info["url"] = tab.displayURL
            info["title"] = tab.title
            if let visitType = self.getVisitTypeForTab(tab, navigation: navigation)?.rawValue {
                info["visitType"] = visitType
            }
            notificationCenter.postNotificationName("LocationChange", object: self, userInfo: info)

            // The screenshot immediately after didFinishNavigation is actually a screenshot of the
            // previous page, presumably due to some iOS bug. Adding a small delay seems to fix this,
            // and the current page gets captured as expected.
            let time = dispatch_time(DISPATCH_TIME_NOW, Int64(100 * NSEC_PER_MSEC))
            dispatch_after(time, dispatch_get_main_queue()) {
                if webView.URL != url {
                    // The page changed during the delay, so we missed our chance to get a thumbnail.
                    return
                }

                if let screenshot = self.screenshotHelper.takeScreenshot(tab, aspectRatio: CGFloat(ThumbnailCellUX.ImageAspectRatio), quality: 0.5) {
                    let thumbnail = Thumbnail(image: screenshot)
                    self.profile.thumbnails.set(url, thumbnail: thumbnail, complete: nil)
                }
            }

            // Fire the readability check. This is here and not in the pageShow event handler in ReaderMode.js anymore
            // because that event wil not always fire due to unreliable page caching. This will either let us know that
            // the currently loaded page can be turned into reading mode or if the page already is in reading mode. We
            // ignore the result because we are being called back asynchronous when the readermode status changes.
            webView.evaluateJavaScript("_firefox_ReaderMode.checkReadability()", completionHandler: nil)
        }

        if tab === tabManager.selectedTab {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil)
            // must be followed by LayoutChanged, as ScreenChanged will make VoiceOver
            // cursor land on the correct initial element, but if not followed by LayoutChanged,
            // VoiceOver will sometimes be stuck on the element, not allowing user to move
            // forward/backward. Strange, but LayoutChanged fixes that.
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil)
        }
    }
}

extension BrowserViewController: WKUIDelegate {
    func webView(webView: WKWebView, createWebViewWithConfiguration configuration: WKWebViewConfiguration, forNavigationAction navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // If the page uses window.open() or target="_blank", open the page in a new tab.
        // TODO: This doesn't work for window.open() without user action (bug 1124942).
        let tab = tabManager.addTab(request: navigationAction.request, configuration: configuration)
        tabManager.selectTab(tab)
        return tab.webView
    }

    func webView(webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: () -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript alerts.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler()
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: (Bool) -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript confirm dialogs.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: message, preferredStyle: UIAlertControllerStyle.Alert)
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(true)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(false)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    func webView(webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: (String!) -> Void) {
        tabManager.selectTab(tabManager[webView])

        // Show JavaScript input dialogs.
        let title = frame.request.URL!.host
        let alertController = UIAlertController(title: title, message: prompt, preferredStyle: UIAlertControllerStyle.Alert)
        var input: UITextField!
        alertController.addTextFieldWithConfigurationHandler({ (textField: UITextField!) in
            textField.text = defaultText
            input = textField
        })
        alertController.addAction(UIAlertAction(title: OKString, style: UIAlertActionStyle.Default, handler: { _ in
            completionHandler(input.text)
        }))
        alertController.addAction(UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: { _ in
            completionHandler(nil)
        }))
        presentViewController(alertController, animated: true, completion: nil)
    }

    /// Invoked when an error occurs during a committed main frame navigation.
    func webView(webView: WKWebView, didFailNavigation navigation: WKNavigation!, withError error: NSError) {
        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            return
        }

        // Ignore the "Plug-in handled load" error. Which is more like a notification than an error.
        // Note that there are no constants in the SDK for the WebKit domain or error codes.
        if error.domain == "WebKitErrorDomain" && error.code == 204 {
            return
        }

        if let url = error.userInfo?["NSErrorFailingURLKey"] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)
        }
    }

    /// Invoked when an error occurs while starting to load data for the main frame.
    func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: NSError) {
        if error.code == Int(CFNetworkErrors.CFURLErrorCancelled.rawValue) {
            return
        }

        if let url = error.userInfo?["NSErrorFailingURLKey"] as? NSURL {
            ErrorPageHelper().showPage(error, forUrl: url, inWebView: webView)
        }
    }

    func webView(webView: WKWebView, decidePolicyForNavigationResponse navigationResponse: WKNavigationResponse, decisionHandler: (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(WKNavigationResponsePolicy.Allow)
            return
        }

        let error = NSError(domain: ErrorPageHelper.MozDomain, code: Int(ErrorPageHelper.MozErrorDownloadsNotEnabled), userInfo: [NSLocalizedDescriptionKey: "Downloads aren't supported in Firefox yet (but we're working on it)."])
        ErrorPageHelper().showPage(error, forUrl: navigationResponse.response.URL!, inWebView: webView)
        decisionHandler(WKNavigationResponsePolicy.Allow)
    }
}

extension BrowserViewController: ReaderModeDelegate, UIPopoverPresentationControllerDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser) {
        // If this reader mode availability state change is for the tab that we currently show, then update
        // the button. Otherwise do nothing and the button will be updated when the tab is made active.
        if tabManager.selectedTab === browser {
            log.debug("New readerModeState: \(state.rawValue)")
            urlBar.updateReaderModeState(state)
        }
    }

    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser) {
        self.showReaderModeBar(animated: true)
        browser.showContent(animated: true)
    }

    // Returning None here makes sure that the Popover is actually presented as a Popover and
    // not as a full-screen modal, which is the default on compact device classes.
    func adaptivePresentationStyleForPresentationController(controller: UIPresentationController) -> UIModalPresentationStyle {
        return UIModalPresentationStyle.None
    }
}

extension BrowserViewController: ReaderModeStyleViewControllerDelegate {
    func readerModeStyleViewController(readerModeStyleViewController: ReaderModeStyleViewController, didConfigureStyle style: ReaderModeStyle) {
        // Persist the new style to the profile
        let encodedStyle: [String:AnyObject] = style.encode()
        profile.prefs.setObject(encodedStyle, forKey: ReaderModeProfileKeyStyle)
        // Change the reader mode style on all tabs that have reader mode active
        for tabIndex in 0..<tabManager.count {
            if let tab = tabManager[tabIndex] {
                if let readerMode = tab.getHelper(name: "ReaderMode") as? ReaderMode {
                    if readerMode.state == ReaderModeState.Active {
                        readerMode.style = style
                    }
                }
            }
        }
    }
}

extension BrowserViewController : UIViewControllerTransitioningDelegate {
    func animationControllerForDismissedController(dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: false)
    }

    func animationControllerForPresentedController(presented: UIViewController, presentingController presenting: UIViewController, sourceController source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return TransitionManager(show: true)
    }
}

extension BrowserViewController : Transitionable {
    private func headerTransformToCellFrame(frame: CGRect) -> CGAffineTransform {
        let scale = frame.size.width / header.frame.size.width
        // Since the scale will happen in the center of the frame, we move this so the centers of the two frames overlap.
        let tx = frame.origin.x + frame.width/2 - (header.frame.origin.x + header.frame.width/2)
        let ty = frame.origin.y - header.frame.origin.y * scale * 2 // Move this up a little actually keeps it above the web page. I'm not sure what you want
        var transform = CGAffineTransformMakeTranslation(tx, ty)
        return CGAffineTransformScale(transform, scale, scale)
    }

    private func footerTransformToCellFrame(frame: CGRect) -> CGAffineTransform {
        let tx = frame.origin.x + frame.width/2 - (footer.frame.origin.x + footer.frame.width/2)
        var footerTransform = CGAffineTransformMakeTranslation(tx, -footer.frame.origin.y + frame.origin.y + frame.size.height - footer.frame.size.height)
        let footerScale = frame.size.width / footer.frame.size.width
        return CGAffineTransformScale(footerTransform, footerScale, footerScale)
    }

    func transitionablePreHide(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = true
            }
        }
        self.homePanelController?.view.hidden = true
    }

    func transitionablePreShow(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's off screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = true
            }
        }

        // Move over the transforms to reflect where the opening tab is coming from instead of where the previous tab was
        if let frame = options.cellFrame {
            header.transform = CGAffineTransformIdentity
            footer.transform = CGAffineTransformIdentity
            header.transform = headerTransformToCellFrame(frame)
            footer.transform = footerTransformToCellFrame(frame)
        }

        self.homePanelController?.view.hidden = true
    }

    func transitionableWillShow(transitionable: Transitionable, options: TransitionOptions) {
        view.alpha = 1

        header.transform = CGAffineTransformIdentity
        footer.transform = CGAffineTransformIdentity
    }

    func transitionableWillHide(transitionable: Transitionable, options: TransitionOptions) {
        view.alpha = 0

        if let frame = options.cellFrame {
            header.transform = headerTransformToCellFrame(frame)
            footer.transform = footerTransformToCellFrame(frame)
        }
    }

    func transitionableWillComplete(transitionable: Transitionable, options: TransitionOptions) {
        // Move all the webview's back on screen
        for i in 0..<tabManager.count {
            if let tab = tabManager[i] {
                tab.webView?.hidden = false
            }
        }

        self.homePanelController?.view.hidden = false
        if options.toView === self {
            startTrackingAccessibilityStatus()
        } else {
            stopTrackingAccessibilityStatus()
        }
    }
}

extension BrowserViewController {
    func showReaderModeBar(#animated: Bool) {
        if self.readerModeBar == nil {
            let readerModeBar = ReaderModeBarView(frame: CGRectZero)
            readerModeBar.delegate = self
            view.insertSubview(readerModeBar, belowSubview: header)
            self.readerModeBar = readerModeBar
        }

        if let readerModeBar = readerModeBar {
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    readerModeBar.unread = record.unread
                    readerModeBar.added = true
                } else {
                    readerModeBar.unread = true
                    readerModeBar.added = false
                }
            } else {
                readerModeBar.unread = true
                readerModeBar.added = false
            }
        }

        self.updateViewConstraints()
    }

    func hideReaderModeBar(#animated: Bool) {
        if let readerModeBar = self.readerModeBar {
            readerModeBar.removeFromSuperview()
            self.readerModeBar = nil
            self.updateViewConstraints()
        }
    }

    /// There are two ways we can enable reader mode. In the simplest case we open a URL to our internal reader mode
    /// and be done with it. In the more complicated case, reader mode was already open for this page and we simply
    /// navigated away from it. So we look to the left and right in the BackForwardList to see if a readerized version
    /// of the current page is there. And if so, we go there.

    func enableReaderMode() {
        if let tab = tabManager.selectedTab,
            let webView = tab.webView,
            let backList = webView.backForwardList.backList as? [WKBackForwardListItem],
            let forwardList = webView.backForwardList.forwardList as? [WKBackForwardListItem] {

            if let currentURL = webView.backForwardList.currentItem?.URL {
                if let readerModeURL = ReaderModeUtils.encodeURL(currentURL) {
                    if backList.count > 1 && backList.last?.URL == readerModeURL {
                        webView.goToBackForwardListItem(backList.last!)
                    } else if forwardList.count > 0 && forwardList.first?.URL == readerModeURL {
                        webView.goToBackForwardListItem(forwardList.first!)
                    } else {
                        // Store the readability result in the cache and load it. This will later move to the ReadabilityHelper.
                        webView.evaluateJavaScript("\(ReaderModeNamespace).readerize()", completionHandler: { (object, error) -> Void in
                            if let readabilityResult = ReadabilityResult(object: object) {
                                ReaderModeCache.sharedInstance.put(currentURL, readabilityResult, error: nil)
                                if let nav = webView.loadRequest(NSURLRequest(URL: readerModeURL)) {
                                    self.ignoreNavigationInTab(tab, navigation: nav)
                                }
                            }
                        })
                    }
                }
            }
        }
    }

    /// Disabling reader mode can mean two things. In the simplest case we were opened from the reading list, which
    /// means that there is nothing in the BackForwardList except the internal url for the reader mode page. In that
    /// case we simply open a new page with the original url. In the more complicated page, the non-readerized version
    /// of the page is either to the left or right in the BackForwardList. If that is the case, we navigate there.

    func disableReaderMode() {
        if let tab = tabManager.selectedTab,
            let webView = tab.webView {
            let backList = webView.backForwardList.backList as! [WKBackForwardListItem]
            let forwardList = webView.backForwardList.forwardList as! [WKBackForwardListItem]

            if let currentURL = webView.backForwardList.currentItem?.URL {
                if let originalURL = ReaderModeUtils.decodeURL(currentURL) {
                    if backList.count > 1 && backList.last?.URL == originalURL {
                        webView.goToBackForwardListItem(backList.last!)
                    } else if forwardList.count > 0 && forwardList.first?.URL == originalURL {
                        webView.goToBackForwardListItem(forwardList.first!)
                    } else {
                        if let nav = webView.loadRequest(NSURLRequest(URL: originalURL)) {
                            self.ignoreNavigationInTab(tab, navigation: nav)
                        }
                    }
                }
            }
        }
    }
}

extension BrowserViewController: ReaderModeBarViewDelegate {
    func readerModeBar(readerModeBar: ReaderModeBarView, didSelectButton buttonType: ReaderModeBarButtonType) {
        switch buttonType {
        case .Settings:
            if let readerMode = tabManager.selectedTab?.getHelper(name: "ReaderMode") as? ReaderMode where readerMode.state == ReaderModeState.Active {
                var readerModeStyle = DefaultReaderModeStyle
                if let dict = profile.prefs.dictionaryForKey(ReaderModeProfileKeyStyle) {
                    if let style = ReaderModeStyle(dict: dict) {
                        readerModeStyle = style
                    }
                }
                
                let readerModeStyleViewController = ReaderModeStyleViewController()
                readerModeStyleViewController.delegate = self
                readerModeStyleViewController.readerModeStyle = readerModeStyle
                readerModeStyleViewController.modalPresentationStyle = UIModalPresentationStyle.Popover
                
                let popoverPresentationController = readerModeStyleViewController.popoverPresentationController
                popoverPresentationController?.backgroundColor = UIColor.whiteColor()
                popoverPresentationController?.delegate = self
                popoverPresentationController?.sourceView = readerModeBar
                popoverPresentationController?.sourceRect = CGRect(x: readerModeBar.frame.width/2, y: UIConstants.ToolbarHeight, width: 1, height: 1)
                popoverPresentationController?.permittedArrowDirections = UIPopoverArrowDirection.Up
                
                self.presentViewController(readerModeStyleViewController, animated: true, completion: nil)
            }

        case .MarkAsRead:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.updateRecord(record, unread: false) // TODO Check result, can this fail?
                    readerModeBar.unread = false
                }
            }

        case .MarkAsUnread:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.updateRecord(record, unread: true) // TODO Check result, can this fail?
                    readerModeBar.unread = true
                }
            }

        case .AddToReadingList:
            if let tab = tabManager.selectedTab,
               let url = tab.url where ReaderModeUtils.isReaderModeURL(url) {
                if let url = ReaderModeUtils.decodeURL(url), let absoluteString = url.absoluteString {
                    let result = profile.readingList?.createRecordWithURL(absoluteString, title: tab.title ?? "", addedBy: UIDevice.currentDevice().name) // TODO Check result, can this fail?
                    readerModeBar.added = true
                }
            }

        case .RemoveFromReadingList:
            if let url = self.tabManager.selectedTab?.displayURL?.absoluteString, result = profile.readingList?.getRecordWithURL(url) {
                if let successValue = result.successValue, record = successValue {
                    profile.readingList?.deleteRecord(record) // TODO Check result, can this fail?
                    readerModeBar.added = false
                }
            }
        }
    }
}

private class BrowserScreenshotHelper: ScreenshotHelper {
    private weak var controller: BrowserViewController?

    init(controller: BrowserViewController) {
        self.controller = controller
    }

    func takeScreenshot(tab: Browser, aspectRatio: CGFloat, quality: CGFloat) -> UIImage? {
        if let url = tab.url {
            if url == UIConstants.AboutHomeURL {
                if let homePanel = controller?.homePanelController {
                    return homePanel.view.screenshot(aspectRatio, quality: quality)
                }
            } else {
                let offset = CGPointMake(0, -(tab.webView?.scrollView.contentInset.top ?? 0))
                return tab.webView?.screenshot(aspectRatio, offset: offset, quality: quality)
            }
        }

        return nil
    }
}

extension BrowserViewController: IntroViewControllerDelegate {
    func presentIntroViewController(force: Bool = false) {
        if force || profile.prefs.intForKey(IntroViewControllerSeenProfileKey) == nil {
            let introViewController = IntroViewController()
            introViewController.delegate = self
            // On iPad we present it modally in a controller
            if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
                introViewController.preferredContentSize = CGSize(width: IntroViewControllerUX.Width, height: IntroViewControllerUX.Height)
                introViewController.modalPresentationStyle = UIModalPresentationStyle.FormSheet
            }
            presentViewController(introViewController, animated: false) {
                self.profile.prefs.setInt(1, forKey: IntroViewControllerSeenProfileKey)
            }
        }
    }

    func introViewControllerDidFinish(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true, completion: nil)
    }

    func presentSignInViewController() {
        // TODO When bug 1161151 has been resolved we can jump directly to the sign in screen
        let settingsNavigationController = SettingsNavigationController()
        settingsNavigationController.profile = self.profile
        settingsNavigationController.tabManager = self.tabManager
		settingsNavigationController.modalPresentationStyle = .FormSheet
        self.presentViewController(settingsNavigationController, animated: true, completion: nil)
    }

    func introViewControllerDidRequestToLogin(introViewController: IntroViewController) {
        introViewController.dismissViewControllerAnimated(true, completion: { () -> Void in
            self.presentSignInViewController()
        })
    }
}

extension BrowserViewController: ContextMenuHelperDelegate {
    func contextMenuHelper(contextMenuHelper: ContextMenuHelper, didLongPressElements elements: ContextMenuHelper.Elements, gestureRecognizer: UILongPressGestureRecognizer) {
        let actionSheetController = UIAlertController(title: nil, message: nil, preferredStyle: UIAlertControllerStyle.ActionSheet)
        var dialogTitle: String?

        if let url = elements.link {
            dialogTitle = url.absoluteString
            let newTabTitle = NSLocalizedString("Open In New Tab", comment: "Context menu item for opening a link in a new tab")
            let openNewTabAction =  UIAlertAction(title: newTabTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) in
                self.scrollController.showToolbars(animated: !self.scrollController.toolbarsShowing, completion: { _ in
                    self.tabManager.addTab(request: NSURLRequest(URL: url))
                })
            }

            actionSheetController.addAction(openNewTabAction)

            let copyTitle = NSLocalizedString("Copy Link", comment: "Context menu item for copying a link URL to the clipboard")
            let copyAction = UIAlertAction(title: copyTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                var pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = url.absoluteString
            }
            actionSheetController.addAction(copyAction)
        }

        if let url = elements.image {
            if dialogTitle == nil {
                dialogTitle = url.absoluteString
            }

            let photoAuthorizeStatus = PHPhotoLibrary.authorizationStatus()
            let saveImageTitle = NSLocalizedString("Save Image", comment: "Context menu item for saving an image")
            let saveImageAction = UIAlertAction(title: saveImageTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                if photoAuthorizeStatus == PHAuthorizationStatus.Authorized || photoAuthorizeStatus == PHAuthorizationStatus.NotDetermined {
                    self.getImage(url) { UIImageWriteToSavedPhotosAlbum($0, nil, nil, nil) }
                } else {
                    let accessDenied = UIAlertController(title: NSLocalizedString("Firefox would like to access your Photos", comment: "See http://mzl.la/1G7uHo7"), message: NSLocalizedString("This allows you to save the image to your Camera Roll.", comment: "See http://mzl.la/1G7uHo7"), preferredStyle: UIAlertControllerStyle.Alert)
                    let dismissAction = UIAlertAction(title: CancelString, style: UIAlertActionStyle.Default, handler: nil)
                    accessDenied.addAction(dismissAction)
                    let settingsAction = UIAlertAction(title: NSLocalizedString("Open Settings", comment: "See http://mzl.la/1G7uHo7"), style: UIAlertActionStyle.Default ) { (action: UIAlertAction!) -> Void in
                        UIApplication.sharedApplication().openURL(NSURL(string: UIApplicationOpenSettingsURLString)!)
                    }
                    accessDenied.addAction(settingsAction)
                    self.presentViewController(accessDenied, animated: true, completion: nil)

                }
            }
            actionSheetController.addAction(saveImageAction)

            let copyImageTitle = NSLocalizedString("Copy Image", comment: "Context menu item for copying an image to the clipboard")
            let copyAction = UIAlertAction(title: copyImageTitle, style: UIAlertActionStyle.Default) { (action: UIAlertAction!) -> Void in
                let pasteBoard = UIPasteboard.generalPasteboard()
                pasteBoard.string = url.absoluteString!
                // TODO: put the actual image on the clipboard
            }
            actionSheetController.addAction(copyAction)
        }

        // If we're showing an arrow popup, set the anchor to the long press location.
        if let popoverPresentationController = actionSheetController.popoverPresentationController {
            popoverPresentationController.sourceView = view
            popoverPresentationController.sourceRect = CGRect(origin: gestureRecognizer.locationInView(view), size: CGSizeMake(0, 16))
            popoverPresentationController.permittedArrowDirections = .Any
        }

        actionSheetController.title = dialogTitle
        var cancelAction = UIAlertAction(title: CancelString, style: UIAlertActionStyle.Cancel, handler: nil)
        actionSheetController.addAction(cancelAction)
        self.presentViewController(actionSheetController, animated: true, completion: nil)
    }

    private func getImage(url: NSURL, success: UIImage -> ()) {
        Alamofire.request(.GET, url)
            .validate(statusCode: 200..<300)
            .response { _, _, data, _ in
                if let data = data as? NSData,
                   let image = UIImage(data: data) {
                    success(image)
                }
            }
    }
}

extension BrowserViewController: KeyboardHelperDelegate {

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillShowWithState state: KeyboardState) {
        keyboardState = state
        // if we are already showing snack bars, adjust them so they sit above the keyboard
        if snackBars.subviews.count > 0 {
            adjustFooterSize(top: nil)
        }
    }

    func keyboardHelper(keyboardHelper: KeyboardHelper, keyboardWillHideWithState state: KeyboardState) {
        keyboardState = nil
        // if we are showing snack bars, adjust them so they are no longer sitting above the keyboard
        if snackBars.subviews.count > 0 {
            adjustFooterSize(top: nil)
        }
    }
}

private struct CrashPromptMessaging {
    static let CrashPromptTitle = NSLocalizedString("Well, this is embarrassing.", comment: "Restore Tabs Prompt Title")
    static let CrashPromptDescription = NSLocalizedString("Looks like Firefox crashed previously. Would you like to restore your tabs?", comment: "Restore Tabs Prompt Description")
    static let CrashPromptAffirmative = NSLocalizedString("Okay", comment: "Restore Tabs Affirmative Action")
    static let CrashPromptNegative = NSLocalizedString("No", comment: "Restore Tabs Negative Action")
}

extension BrowserViewController: UIAlertViewDelegate {
    private enum CrashPromptIndex: Int {
        case Cancel = 0
        case Restore = 1
    }

    func alertView(alertView: UIAlertView, clickedButtonAtIndex buttonIndex: Int) {
        if buttonIndex == CrashPromptIndex.Restore.rawValue {
            tabManager.restoreTabs()
        }

        // In case restore fails, launch at least one tab
        if tabManager.count == 0 {
            let tab = tabManager.addTab()
            tabManager.selectTab(tab)
        }
    }
}

