import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted
                              ? Color.accentColor.opacity(0.07)
                              : Color.secondary.opacity(0.04))
                )
                .animation(.easeInOut(duration: 0.18), value: isTargeted)

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.doc")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                        .scaleEffect(isTargeted ? 1.1 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)
                }

                VStack(spacing: 6) {
                    Text("拖放图片到这里")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text("支持 PNG · JPEG · TIFF · BMP · GIF · HEIC · WebP · PDF")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    vm.openFilePicker()
                } label: {
                    Label("选择文件", systemImage: "folder.badge.plus")
                        .font(.callout)
                        .fontWeight(.medium)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(40)
        }
        .padding(24)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            DropHelper.handle(providers: providers, vm: vm)
        }
    }
}
