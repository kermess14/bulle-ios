import SwiftUI
import UIKit

/// Le lecteur : pages en plein écran, glisser ou taper sur les bords pour tourner, pincer ou double-taper pour zoomer,
/// tape au milieu pour les barres. Sens manga (droite à gauche) et côtés de tape inversés, comme dans Bulle.
struct ReaderScreen: View {
    let book: URL
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var source: PageSource?
    @State private var loaded = false
    @State private var page = 0
    @State private var bars = true
    @AppStorage("bulle.manga") private var manga = false
    @AppStorage("bulle.tapSwap") private var tapSwap = false

    private var count: Int { source?.pageCount ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let source, count > 0 {
                PagerView(source: source, page: $page, manga: manga, tapSwap: tapSwap) {
                    withAnimation(.easeInOut(duration: 0.2)) { bars.toggle() }
                }
                .ignoresSafeArea()
            } else if loaded {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Cet album ne s'ouvre pas (fichier abîmé, ou sans images).")
                    Button("Fermer") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white).padding()
            } else {
                ProgressView().tint(.white)
            }
            if bars && count > 0 { barsOverlay }
        }
        .statusBarHidden(!bars)
        .persistentSystemOverlays(bars ? .automatic : .hidden)
        .task {
            let url = book
            let s = await Task.detached(priority: .userInitiated) { PageSources.open(url) }.value
            if let s, s.pageCount > 0, let p = library.progress(for: book), !p.done {
                page = min(max(0, p.page), s.pageCount - 1)   // reprise là où on s'était arrêté (un album lu repart du début)
            }
            source = s
            loaded = true
        }
        .onChange(of: page) { p in
            if count > 0 { library.saveProgress(book, page: p, count: count) }
        }
    }

    private var barsOverlay: some View {
        VStack {
            HStack(spacing: 14) {
                Button { dismiss() } label: { Image(systemName: "chevron.backward").font(.title3.weight(.semibold)).frame(width: 40, height: 40) }
                Text(book.deletingPathExtension().lastPathComponent)
                    .font(.headline).lineLimit(1)
                Spacer()
                Button { tapSwap.toggle() } label: {
                    Image(systemName: tapSwap ? "hand.tap.fill" : "hand.tap").frame(width: 40, height: 40)
                }
                .accessibilityLabel(tapSwap ? "Tape à gauche pour avancer" : "Tape à droite pour avancer")
                Button { manga.toggle() } label: {
                    Text(manga ? "← Manga" : "BD →").font(.subheadline.weight(.semibold)).frame(minWidth: 64, minHeight: 40)
                }
                .accessibilityLabel(manga ? "Sens manga, de droite à gauche" : "Sens occidental, de gauche à droite")
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial)
            Spacer()
            HStack(spacing: 12) {
                Text("\(page + 1) / \(count)").font(.subheadline.monospacedDigit()).frame(minWidth: 70)
                if count > 1 {
                    Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }),
                           in: 0...Double(count - 1), step: 1)
                        .environment(\.layoutDirection, manga ? .rightToLeft : .leftToRight)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }
}

/// Les pages côte à côte, qu'on fait glisser (UIPageViewController) ; chaque page se zoome toute seule.
struct PagerView: UIViewControllerRepresentable {
    let source: PageSource
    @Binding var page: Int
    let manga: Bool
    let tapSwap: Bool
    let onCenterTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                       options: [.interPageSpacing: 14])
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .black
        pvc.setViewControllers([context.coordinator.pageController(page)], direction: .forward, animated: false)
        context.coordinator.pager = pvc
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        let mangaChanged = c.parent.manga != manga
        c.parent = self
        let shown = (pvc.viewControllers?.first as? ZoomPageController)?.index
        if shown != page || mangaChanged {
            // page choisie avec la barre, ou sens de lecture changé : on y va sans animation
            pvc.setViewControllers([c.pageController(page)], direction: .forward, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PagerView
        weak var pager: UIPageViewController?
        private let cache = NSCache<NSNumber, UIImage>()
        private let queue = DispatchQueue(label: "bulle.pages", qos: .userInitiated)

        init(_ parent: PagerView) {
            self.parent = parent
            cache.countLimit = 8
        }

        var count: Int { parent.source.pageCount }

        func pageController(_ index: Int) -> ZoomPageController {
            let vc = ZoomPageController(index: index)
            vc.loader = { [weak self] i, maxPixel, done in self?.load(i, maxPixel: maxPixel, done: done) }
            vc.onTap = { [weak self, weak vc] x, zoomed in self?.tap(x: x, zoomed: zoomed, from: vc) }
            return vc
        }

        func load(_ index: Int, maxPixel: CGFloat, done: @escaping (UIImage?) -> Void) {
            let key = NSNumber(value: index)
            if let img = cache.object(forKey: key), max(img.size.width, img.size.height) * img.scale >= maxPixel * 0.9 { done(img); return }
            let src = parent.source
            queue.async { [weak self] in
                let img = src.image(at: index, maxPixel: maxPixel)
                DispatchQueue.main.async {
                    if let img { self?.cache.setObject(img, forKey: key) }
                    done(img)
                }
            }
        }

        // glisser : en sens manga, la page suivante est à gauche
        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? ZoomPageController)?.index else { return nil }
            let j = parent.manga ? i + 1 : i - 1
            return (0..<count).contains(j) ? pageController(j) : nil
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let i = (vc as? ZoomPageController)?.index else { return nil }
            let j = parent.manga ? i - 1 : i + 1
            return (0..<count).contains(j) ? pageController(j) : nil
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let i = (pvc.viewControllers?.first as? ZoomPageController)?.index else { return }
            if parent.page != i { parent.page = i }
        }

        /// Tape : bord gauche ou droit = page précédente ou suivante (selon le sens et l'inversion), milieu = barres.
        /// Page agrandie : on regarde, on ne tourne pas (seules les barres).
        func tap(x: CGFloat, zoomed: Bool, from vc: ZoomPageController?) {
            guard !zoomed, x < 0.3 || x > 0.7 else { parent.onCenterTap(); return }
            let leftMeansNext = parent.manga != parent.tapSwap
            let delta = (x < 0.3) == leftMeansNext ? 1 : -1
            guard let vc, let pvc = pager else { return }
            let j = vc.index + delta
            guard (0..<count).contains(j) else { return }
            // la page suivante arrive de droite (de gauche en sens manga)
            let direction: UIPageViewController.NavigationDirection = (delta > 0) != parent.manga ? .forward : .reverse
            pvc.setViewControllers([pageController(j)], direction: direction, animated: true)
            parent.page = j
        }
    }
}

/// Une page : image ajustée à l'écran dans une vue qui se zoome (pincer, double tape) et se déplace une fois agrandie.
final class ZoomPageController: UIViewController, UIScrollViewDelegate {
    let index: Int
    var loader: ((Int, CGFloat, @escaping (UIImage?) -> Void) -> Void)?
    var onTap: ((CGFloat, Bool) -> Void)?
    private let scroll = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var loadedFor: CGFloat = 0

    init(index: Int) { self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("pas de storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.bouncesZoom = true
        view.addSubview(scroll)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        scroll.addSubview(imageView)
        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)
        spinner.startAnimating()

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        single.require(toFail: double)
        scroll.addGestureRecognizer(single)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.zoomScale == 1 { layoutImage() }
        // assez de pixels pour l'écran, et un peu plus pour zoomer (au plus 4 096 px)
        let want = min(4096, max(view.bounds.width, view.bounds.height) * traitCollection.displayScale * 1.6)
        if want > loadedFor * 1.2 {
            loadedFor = want
            loader?(index, want) { [weak self] img in
                guard let self else { return }
                self.spinner.stopAnimating()
                self.imageView.image = img
                if self.scroll.zoomScale == 1 { self.layoutImage() }
            }
        }
    }

    private func layoutImage() {
        let b = scroll.bounds.size
        guard b.width > 0, b.height > 0 else { return }
        var size = b
        if let img = imageView.image, img.size.width > 0, img.size.height > 0 {
            let k = min(b.width / img.size.width, b.height / img.size.height)
            size = CGSize(width: img.size.width * k, height: img.size.height * k)
        }
        imageView.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        centerImage()
    }

    private func centerImage() {
        let b = scroll.bounds.size, c = scroll.contentSize
        scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - c.height) / 2), left: max(0, (b.width - c.width) / 2),
                                           bottom: 0, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let p = g.location(in: imageView), z: CGFloat = 2.5
            let w = scroll.bounds.width / z, h = scroll.bounds.height / z
            scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    @objc private func singleTap(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x / max(1, view.bounds.width)
        onTap?(x, scroll.zoomScale > 1.01)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scroll.setZoomScale(1, animated: false)   // en revenant sur la page, elle est entière
    }
}
