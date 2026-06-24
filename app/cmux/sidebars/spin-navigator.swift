VStack(alignment: .leading, spacing: 10) {
    HStack {
        Image(systemName: "circle.hexagongrid.fill")
            .foregroundColor("#22C55E")
            .imageScale(.large)
        VStack(alignment: .leading, spacing: 2) {
            Text("SPIN")
                .font(.headline)
                .fontWeight(.semibold)
            Text("\(workspaceCount) workspaces")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Spacer()
        Text(clock.time)
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
    }

    Divider()

    Reorderable(workspaces, move: "workspace.reorder") { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(w.selected ? "#22C55E" : (w.unread > 0 ? "#EAB308" : "#5B6B73"))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.title)
                        .font(.system(size: 13))
                        .fontWeight(w.selected ? .semibold : .regular)
                        .lineLimit(1)
                    if let description = w.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if w.unread > 0 {
                    Text("\(w.unread)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor("#EAB308")
                }
            }
            .padding(6)
            .background(w.selected ? "#14313A" : "#081E26")
            .cornerRadius(6)
        }
    }

    Divider()

    VStack(alignment: .leading, spacing: 6) {
        Button(action: { cmux("workspace.create", title: "New SPIN Project") }) {
            Label("New Project Floor", systemImage: "plus.circle")
        }
        Button(action: { cmux("sidebar.custom.open", name: "spin-navigator") }) {
            Label("Open Navigator Panel", systemImage: "sidebar.left")
        }
    }
    .font(.caption)
}
.padding(10)
