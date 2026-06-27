VStack(alignment: .leading, spacing: 10) {
    HStack {
        Image(systemName: "circle.hexagongrid.fill")
            .foregroundColor("#FF2BD6")
            .imageScale(.large)
        VStack(alignment: .leading, spacing: 2) {
            Text("SPIN")
                .font(.headline)
                .fontWeight(.semibold)
            Text("Navigator")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Spacer()
        Text("\(workspaceCount)")
            .font(.caption)
            .monospacedDigit()
            .foregroundColor("#00E5FF")
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background("#4A003A")
            .cornerRadius(10)
        Text(clock.time)
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(.secondary)
    }

    HStack(spacing: 6) {
        Text("COORDINATOR")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor("#22D3EE")
        Text("PROJECT FLOORS")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor("#FF2BD6")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background("#3D0030")
    .cornerRadius(6)

    Divider()

    Reorderable(workspaces, move: "workspace.reorder") { w in
        Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
            HStack(spacing: 8) {
                Circle()
                    .fill(w.selected ? "#FF2BD6" : (w.unread > 0 ? "#00E5FF" : "#6F5868"))
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
                        .foregroundColor("#00E5FF")
                }
            }
            .padding(6)
            .background(w.selected ? "#6A0053" : "#210019")
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
