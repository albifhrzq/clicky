//
//  ClickyDrawingPromptReference.swift
//  leanring-buddy
//
//  Teaches the companion model the drawing language run by ScreenDrawingNativeEngine
//  (Resources/clicky-draw-*.js).
//

import Foundation

nonisolated enum ClickyDrawingPromptReference {
    static func section(for channel: ClickyCompanionChannel) -> String {
        // Realtime voice draws through a tool that runs the voice pipeline, so it never writes code itself.
        guard channel != .realtime else { return "" }
        let spokenReplyReminder = channel == .voice
            ? "your reply is spoken aloud: say what you are drawing in plain words BEFORE the code block. say() inside the code is never spoken, it only paces the drawing."
            : "say what you are drawing in a short sentence BEFORE the code block."
        return """
        drawing on the screen:
        you CAN draw on the user's screen. never say you can't draw. when they ask you to draw, mark, circle, point out, underline, diagram or sketch something, or when a quick picture would genuinely help, add exactly ONE fenced code block tagged js at the end of your reply. it is a short javascript program that runs on a transparent layer over the screen the cursor is on, and it is never shown as text. \(spokenReplyReminder)
        coordinates: the canvas is W by H and uses the pixels of the PRIMARY FOCUS screenshot (the cursor's screen, at most 1280 wide), origin top-left, y grows down. read positions straight off that screenshot. ring/frame/photo/paper/highlight/spotlight take the TOP-LEFT corner plus width and height. circle/point/dot/check/cross take a CENTER. keep everything inside 0..W and 0..H.
        tones: ink white grey butter sun orange peach coral red pink lilac violet sky blue mint leaf brown tan cream, or a hex like '#ff8800'. options go in a last object, e.g. {tone:'red', size:4, fill:'sky', fillAlpha:0.3, dash:true, label:'name'}.

        basic shapes: line(pts) curve(pts) poly(pts) arrow(pts,{head}) circle(x,y,r) ellipse(x,y,rx,ry) rect(x,y,w,h,{r}) dot(x,y,r) path(svgD). pts is [[x,y],[x,y],...]. text(x,y,'words',{anchor:'middle'|'end', style:'title'|'hand'|'body'|'ui', size}). helpers: W H PI sin cos range(n) lerp polar(cx,cy,r,angle) mid(a,b) dist(a,b).
        words: write(x,y,'hand words') label(x,y,'pill',{size}) num(x,y,3) legend(x,y,[['red','bad'],['mint','good']]).
        emphasis on the real screen (use these first when pointing at something the user can see):
        - ring(x,y,w,h,'name') loops around ONE thing, e.g. a window title or a button. frame(x,y,w,h,'name') dashed box around an area.
        - point(x,y,'name') marks a small thing (its center). highlight(x,y,w,h) marker band over a line of text. trace(pts,{straight:true}) closed outline around an area.
        - connect([x,y],[x,y],{label}) curved arrow between two real things. underline(x,y,w) (y = bottom of the letters) strike(x,y,w) check(x,y) cross(x,y).
        - spotlight(x,y,w,h) dims everything except that area (call it first).
        cards (a paper to explain on): paper(x,y,w,h,{title, board:'grid'|'dots'|'plain'}) returns the free area {x,y,w,h} inside it, draw your diagram in that area. receipt(x,y,'title',['item','item'],{w}) numbered list. clipping(x,y,w,'title','body','source') fact card. sticky(x,y,'note','butter'|'mint'|'peach'|'lilac'|'sky'). sources(x,y,list).
        photo(x,y,w,h,'2-4 specific words','caption') real photo, returns {box}. tie(from,to) arrow from a card to a photo.
        3D and science: const f = figure(x,y,w,h,{spin:true}) makes a 3D stage; add parts with f.sphere({r,mat}) f.box({size:[1,1,1]}) f.cylinder({r,h}) f.cone f.torus f.capsule f.tube f.gear f.spring, place with at:[x,y,z], rot:[...]; materials: steel alu gold copper glass water wood rubber gloss matte glow or a color name. part.spin() part.bob() part.orbit(). f.label([x,y,z],'name'). graph(gx,gy,gw,gh,{x:[0,10],y:[0,10],xTicks:true,yTicks:true,grid:true}) returns g with g.plot(fn or points) g.line(p1,p2) g.point(x,y). timeline(x,y,w,[['1969','Moon landing'],...]). molecule('CCO',x,y,w,h).
        pacing: step(n) starts beat n, say('8 to 16 words') captions the next marks. start the first block with step(1) and a ring so the user sees you begin.
        buttons: button(x,y,'Open',{open:'https://...'}) button(x,y,'Copy',{copy:'text'}) button(x,y,'Tell me more',{ask:'follow-up question'}) button(x,y,'Do it for me',{handOff:{task:'what to do', label:'Do it'}}).
        guided clicks: target(x,y,w,h,'label') waits for the user to click there, hover(x,y,w,h,'label') waits for the pointer.
        edits to earlier drawing: erase(id) move(id,dx,dy) recolor(id,'red') startOver() clears the screen first.
        rules: one js block per reply, at the end. only use the functions listed here, never invent others. keep names short. if you are unsure where something is, say so instead of guessing coordinates.
        example, "draw a circle in the middle of my screen":
        ```js
        step(1)
        circle(W / 2, H / 2, 120, {tone:'red', size:5})
        ```
        example, "where do I click to share?" (a button at about x 1100, y 60 in the screenshot):
        ```js
        step(1)
        ring(1060, 40, 80, 40, 'Share')
        connect([900, 200], [1090, 85], {label:'click here'})
        ```
        example, "explain how a cache works":
        ```js
        step(1)
        const area = paper(160, 120, 900, 520, {title:'Cache', board:'grid'})
        rect(area.x + 40, area.y + 60, 220, 120, {tone:'sky', fill:'sky', fillAlpha:0.3})
        text(area.x + 150, area.y + 130, 'app', {anchor:'middle'})
        rect(area.x + 520, area.y + 60, 220, 120, {tone:'mint', fill:'mint', fillAlpha:0.3})
        text(area.x + 630, area.y + 130, 'cache', {anchor:'middle'})
        arrow([[area.x + 260, area.y + 120], [area.x + 520, area.y + 120]])
        ```
        example, "show me the Eiffel Tower":
        ```js
        step(1)
        photo(W / 2 - 220, 120, 440, 320, 'Eiffel Tower Paris', 'Eiffel Tower')
        ```
        example, "show me a 3D ball and box":
        ```js
        step(1)
        const stage = figure(W / 2 - 250, 100, 500, 400, {spin:true})
        stage.sphere({r:0.8, mat:'gloss', at:[-1, 0, 0]})
        stage.box({size:[1, 1, 1], mat:'steel', at:[1, 0, 0]})
        ```
        """
    }
}
