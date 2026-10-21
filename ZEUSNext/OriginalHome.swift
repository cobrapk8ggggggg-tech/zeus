import SwiftUI

// Geometry and behavior restored from the supplied ZEUS HomePageView.swift.
struct OriginalHome: View {
    @Environment(\.browserTheme) private var theme
    @ObservedObject var model: BrowserModel
    @State private var query = ""
    @State private var adding = false
    @State private var title = ""
    @State private var url = ""
    @State private var showHistory = false
    @State private var opacity: Double = 0
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 50)
            VStack(spacing: 15) {
                Image("ZEUS").resizable().scaledToFit().frame(width: 135, height: 135).padding(.bottom, 5).accessibilityHidden(true)
                Text("ZEUS Browser").font(.system(size: 28, weight: .bold, design: .rounded)).tracking(2)
            }.padding(.bottom, 40).opacity(opacity)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(query.isEmpty ? 0 : 0.5) }
                    TextField("البحث أو إدخال عنوان URL", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing).submitLabel(.search).focused($focused).accessibilityIdentifier("homeSearchField").onSubmit { focused = false; showHistory = false; model.open(query) }
                    Image(systemName: model.data.settings.searchProvider.symbol).font(.system(size: 18))
                }.padding(.horizontal, 15).frame(height: 55).background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 28)).overlay(RoundedRectangle(cornerRadius: 28).stroke(theme.textColor.opacity(0.1), lineWidth: 1))
                if showHistory && !(model.data.searches ?? []).isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array((model.data.searches ?? []).prefix(5)), id: \.self) { suggestion in
                            HStack {
                                Button { model.data.searches?.removeAll { $0 == suggestion }; model.persist() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).padding(6).background(theme.textColor.opacity(0.05), in: Circle()) }
                                Spacer()
                                Button { query = suggestion; focused = false; showHistory = false; model.open(suggestion) } label: { Text(suggestion).font(.system(size: 15, weight: .medium)).lineLimit(1) }
                                Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 14))
                            }.padding(.horizontal, 18).padding(.vertical, 14)
                        }
                    }.background(theme.surfaceColor, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 8).padding(.top, 10)
                }
            }.padding(.horizontal, 20).environment(\.layoutDirection, .leftToRight)
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 4), spacing: 25) {
                    ForEach(model.data.bookmarks) { item in
                        Button { model.open(item.url) } label: {
                            VStack(spacing: 8) {
                                FirstPartyFavicon(site: item).frame(width: 60, height: 60).background(LinearGradient(colors: [theme.textColor.opacity(0.18), theme.textColor.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 75)
                            }
                        }.buttonStyle(.plain).contextMenu { Button("حذف") { model.data.bookmarks.removeAll { $0.id == item.id }; model.persist() } }
                    }
                    Button { adding = true } label: {
                        VStack(spacing: 8) { Image(systemName: "plus").font(.title2).frame(width: 60, height: 60).background(theme.textColor.opacity(0.08), in: Circle()).overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(theme.textColor.opacity(0.35))); Text("إضافة").font(.system(size: 12)).frame(width: 75) }
                    }.buttonStyle(.plain).disabled([.guest, .kiosk].contains(model.profile.role))
                }.padding(.top, 40).padding(.horizontal, 20).padding(.bottom, 100)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.backgroundColor).foregroundStyle(theme.textColor)
            .onChange(of: focused) { _, value in withAnimation(.spring()) { showHistory = value } }
            .onAppear { withAnimation(.easeIn(duration: 0.8)) { opacity = 1 } }
            .fullScreenCover(isPresented: $adding) { addWebsite }
    }
    private var addWebsite: some View {
        NavigationStack {
            Form { TextField("الاسم", text: $title); TextField("الرابط", text: $url).keyboardType(.URL).textInputAutocapitalization(.never) }.settingsPage("إضافة موقع")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { adding = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("حفظ") { if let address = BrowserURL.resolve(url, provider: model.data.settings.searchProvider), BrowserURL.isWeb(address) { model.data.bookmarks.append(Bookmark(title: title.isEmpty ? address.host ?? url : title, url: address.absoluteString)); model.persist(); adding = false } } }
                }
        }.tint(theme.buttonTextColor).preferredColorScheme(theme.light ? .light : .dark)
    }
}
