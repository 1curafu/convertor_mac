import Foundation

/// Minimal PowerPoint writer: one full-bleed picture per slide (used for PDF → PPTX,
/// which keeps every page looking exactly like the PDF).
enum PPTX {
    /// `slides` are JPEG data with their pixel size; the slide size follows the first one's aspect.
    static func write(slides: [(jpeg: Data, width: Int, height: Int)], to output: URL) async throws {
        guard let first = slides.first else { throw ConvertError("No pages to put on slides") }
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
        let rels = "http://schemas.openxmlformats.org/package/2006/relationships"
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let ns = "xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\""
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"

        let slideWidth = 12_192_000
        let slideHeight = Int(Double(slideWidth) * Double(first.height) / Double(max(first.width, 1)))
        var files: [(path: String, data: Data)] = []

        var slideOverrides = ""
        var slideIDs = ""
        var presentationRels = """
        <Relationship Id="rId1" Type="\(r)/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId2" Type="\(r)/theme" Target="theme/theme1.xml"/>
        """
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            slideIDs += "<p:sldId id=\"\(255 + number)\" r:id=\"rId\(number + 2)\"/>"
            presentationRels += "<Relationship Id=\"rId\(number + 2)\" Type=\"\(r)/slide\" Target=\"slides/slide\(number).xml\"/>"

            // Fit the picture inside the slide, centred.
            let scale = min(Double(slideWidth) / Double(slide.width), Double(slideHeight) / Double(slide.height))
            let cx = Int(Double(slide.width) * scale), cy = Int(Double(slide.height) * scale)
            let x = (slideWidth - cx) / 2, y = (slideHeight - cy) / 2

            files.append(("ppt/media/image\(number).jpeg", slide.jpeg))
            files.append(("ppt/slides/slide\(number).xml", (header + """
            <p:sld \(ns)><p:cSld><p:spTree>\(emptyTree)<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(number)"/>\
            <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """).utf8Data))
            files.append(("ppt/slides/_rels/slide\(number).xml.rels", (header + """
            <Relationships xmlns="\(rels)"><Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="\(r)/image" Target="../media/image\(number).jpeg"/></Relationships>
            """).utf8Data))
        }

        files.append(("[Content_Types].xml", (header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        \(slideOverrides)</Types>
        """).utf8Data))
        files.append(("_rels/.rels", (header + """
        <Relationships xmlns="\(rels)"><Relationship Id="rId1" Type="\(r)/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """).utf8Data))
        files.append(("ppt/presentation.xml", (header + """
        <p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/>\
        <p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """).utf8Data))
        files.append(("ppt/_rels/presentation.xml.rels", (header + "<Relationships xmlns=\"\(rels)\">\(presentationRels)</Relationships>").utf8Data))
        files.append(("ppt/slideMasters/slideMaster1.xml", (header + """
        <p:sldMaster \(ns)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" \
        accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """).utf8Data))
        files.append(("ppt/slideMasters/_rels/slideMaster1.xml.rels", (header + """
        <Relationships xmlns="\(rels)"><Relationship Id="rId1" Type="\(r)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="\(r)/theme" Target="../theme/theme1.xml"/></Relationships>
        """).utf8Data))
        files.append(("ppt/slideLayouts/slideLayout1.xml", (header + """
        <p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """).utf8Data))
        files.append(("ppt/slideLayouts/_rels/slideLayout1.xml.rels", (header + """
        <Relationships xmlns="\(rels)"><Relationship Id="rId1" Type="\(r)/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """).utf8Data))
        files.append(("ppt/theme/theme1.xml", (header + theme(a)).utf8Data))

        try await ZipPackage.write(files, to: output)
    }

    /// The smallest theme PowerPoint accepts: colours, fonts and the three style lists.
    private static func theme(_ a: String) -> String {
        func color(_ name: String, _ hex: String) -> String { "<a:\(name)><a:srgbClr val=\"\(hex)\"/></a:\(name)>" }
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\">\(solid)</a:ln>"
        return """
        <a:theme xmlns:a="\(a)" name="Convertor"><a:themeElements>\
        <a:clrScheme name="Convertor">\
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        \(color("dk2", "1F1F1F"))\(color("lt2", "EEECE1"))\(color("accent1", "FF4F00"))\(color("accent2", "ED7D31"))\
        \(color("accent3", "A5A5A5"))\(color("accent4", "FFC000"))\(color("accent5", "5B9BD5"))\(color("accent6", "70AD47"))\
        \(color("hlink", "0563C1"))\(color("folHlink", "954F72"))</a:clrScheme>\
        <a:fontScheme name="Convertor"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
        <a:fmtScheme name="Convertor">\
        <a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>\
        <a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
        <a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst>\
        </a:fmtScheme></a:themeElements></a:theme>
        """
    }
}
