import Foundation
import ImageIO
import Testing
@testable import ImageViewer

@Suite("Search & filters")
struct FilterTests {
    let folder = TempFolder()
    let photo: FileItem
    let video: FileItem
    let raw: FileItem

    init() throws {
        photo = Fixtures.item(Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("Beach Day.jpg")))
        FileManager.default.createFile(atPath: folder.file("clip.mov").path, contents: Data([0, 0, 0, 0]))
        video = Fixtures.item(folder.file("clip.mov"))
        FileManager.default.createFile(atPath: folder.file("shot.dng").path, contents: Data([0, 0, 0, 0]))
        raw = Fixtures.item(folder.file("shot.dng"))
    }

    let june2021 = DateComponents(calendar: .current, year: 2021, month: 6, day: 15, hour: 18).date!

    @Test func typeFilter() {
        #expect(photo.isRaw == false && video.isVideo && raw.isRaw)
        #expect(MediaFilter(type: .photos).matches(photo, captureDate: june2021, labels: []))
        #expect(!MediaFilter(type: .photos).matches(video, captureDate: june2021, labels: []))
        #expect(MediaFilter(type: .videos).matches(video, captureDate: june2021, labels: []))
        #expect(MediaFilter(type: .raw).matches(raw, captureDate: june2021, labels: []))
        #expect(!MediaFilter(type: .raw).matches(photo, captureDate: june2021, labels: []))
    }

    @Test func searchMatchesNamesAndRecognizedContents() {
        #expect(MediaFilter(searchText: "beach").matches(photo, captureDate: june2021, labels: []))
        #expect(MediaFilter(searchText: "DAY").matches(photo, captureDate: june2021, labels: []))
        #expect(MediaFilter(searchText: "dog").matches(photo, captureDate: june2021, labels: ["dog", "grass"]))
        // Every word must match (name or contents).
        #expect(MediaFilter(searchText: "beach dog").matches(photo, captureDate: june2021, labels: ["dog"]))
        #expect(!MediaFilter(searchText: "beach cat").matches(photo, captureDate: june2021, labels: ["dog"]))
        #expect(MediaFilter(searchText: "  ").matches(photo, captureDate: june2021, labels: []))
    }

    @Test func foldersOnlyFilteredBySearch() {
        let folderItem = FileItem(url: folder.url)!
        #expect(MediaFilter(type: .videos).matchesFolder(folderItem))
        #expect(!MediaFilter(searchText: "zzz").matchesFolder(folderItem))
    }

    @Test func customDateRangeIncludesWholeDays() {
        let from = DateComponents(calendar: .current, year: 2021, month: 6, day: 1).date!
        let to = DateComponents(calendar: .current, year: 2021, month: 6, day: 15).date!
        let range = DateFilter.custom.range(from: to, to: from) // order doesn't matter
        #expect(range.contains(june2021)) // 6pm on the last day is still included
        #expect(!range.contains(DateComponents(calendar: .current, year: 2021, month: 6, day: 16, hour: 0, minute: 1).date!))
        #expect(MediaFilter(dates: range).matches(photo, captureDate: june2021, labels: []))
    }

    @Test func lastYearMeansTheWholePreviousCalendarYear() {
        let range = DateFilter.lastYear.range(from: .now, to: .now)
        let year = Calendar.current.component(.year, from: .now) - 1
        #expect(range.contains(DateComponents(calendar: .current, year: year, month: 1, day: 1, hour: 0, minute: 0, second: 1).date!))
        #expect(range.contains(DateComponents(calendar: .current, year: year, month: 12, day: 31, hour: 23).date!))
        #expect(!range.contains(DateComponents(calendar: .current, year: year + 1, month: 1, day: 1, hour: 1).date!))
    }
}

@Suite("Metadata index")
struct MediaIndexTests {
    @Test func readsDateTakenAndLocation() {
        let folder = TempFolder()
        let url = Fixtures.write(
            Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("a.jpg"),
            taken: "2021:06:15 18:30:00", latitude: -33.8688, longitude: 151.2093
        )
        let info = MediaIndex.readImage(url)
        #expect(info.captureDate == DateComponents(calendar: .current, year: 2021, month: 6, day: 15, hour: 18, minute: 30).date)
        #expect(info.coordinate == Coordinate(latitude: -33.8688, longitude: 151.2093)) // S and E handled
    }

    @Test func noMetadataMeansNoDateOrPlace() {
        let folder = TempFolder()
        let info = MediaIndex.readImage(Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file("b.jpg")))
        #expect(info.captureDate == nil && info.coordinate == nil)
    }

    @Test("Parses video location strings (ISO 6709)", arguments: [
        ("+37.3349-122.0090+010.000/", 37.3349, -122.009),
        ("-33.8688+151.2093/", -33.8688, 151.2093),
    ])
    func iso6709(string: String, latitude: Double, longitude: Double) {
        #expect(MediaIndex.parseISO6709(string) == Coordinate(latitude: latitude, longitude: longitude))
    }

    @Test func rejectsGarbageLocation() {
        #expect(MediaIndex.parseISO6709("somewhere nice") == nil)
    }
}

@Suite("Batch rename plans")
struct RenamePlanTests {
    let folder = TempFolder()

    func items(_ names: [String]) -> [FileItem] {
        names.map { Fixtures.item(Fixtures.write(Fixtures.solid(CGColor(gray: 0.5, alpha: 1)), to: folder.file($0))) }
    }

    @Test func tokensAreFilledIn() {
        let files = items(["IMG_1.jpg", "IMG_2.jpg"])
        let date = DateComponents(calendar: .current, year: 2021, month: 6, day: 5, hour: 9, minute: 7, second: 3).date!
        let plans = BrowserModel.renamePlans(
            for: files, template: "{date}_{time}_{n}_{name}_{year}{month}{day}", start: 8, digits: 3,
            dates: Dictionary(uniqueKeysWithValues: files.map { ($0.url, date) })
        )
        #expect(plans.map(\.newName) == [
            "2021-06-05_090703_008_IMG_1_20210605.jpg",
            "2021-06-05_090703_009_IMG_2_20210605.jpg",
        ])
        #expect(BrowserModel.problem(with: plans) == nil)
    }

    @Test func detectsDuplicateNames() {
        let plans = BrowserModel.renamePlans(for: items(["a.jpg", "b.jpg"]), template: "same", start: 1, digits: 1, dates: [:])
        #expect(BrowserModel.problem(with: plans)?.contains("both be named") == true)
    }

    @Test("Rejects invalid names", arguments: ["", "a/b", "a:b", ".hidden"])
    func rejectsInvalidNames(template: String) {
        let plans = BrowserModel.renamePlans(for: items(["a.jpg"]), template: template, start: 1, digits: 1, dates: [:])
        #expect(BrowserModel.problem(with: plans) != nil)
    }

    @Test func refusesToOverwriteAnotherFile() {
        let files = items(["a.jpg", "taken.jpg"])
        let plans = [RenamePlan(item: files[0], newName: "taken.jpg")]
        #expect(BrowserModel.problem(with: plans)?.contains("already exists") == true)
    }

    @Test func allowsSwappingNamesWithinTheBatch() {
        let files = items(["a.jpg", "b.jpg"])
        let plans = [RenamePlan(item: files[0], newName: "b.jpg"), RenamePlan(item: files[1], newName: "a.jpg")]
        #expect(BrowserModel.problem(with: plans) == nil)
    }
}
