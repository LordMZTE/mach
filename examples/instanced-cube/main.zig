const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const glfw = @import("glfw");
const zm = @import("zmath");
const Vertex = @import("cube_mesh.zig").Vertex;
const vertices = @import("cube_mesh.zig").vertices;

const UniformBufferObject = struct {
    mat: zm.Mat,
};

var timer: std.time.Timer = undefined;

pipeline: gpu.RenderPipeline,
queue: gpu.Queue,
vertex_buffer: gpu.Buffer,
uniform_buffer: gpu.Buffer,
bind_group: gpu.BindGroup,

const App = @This();

pub fn init(app: *App, engine: *mach.Engine) !void {
    timer = try std.time.Timer.start();

    engine.core.internal.window.setKeyCallback(struct {
        fn callback(window: glfw.Window, key: glfw.Key, scancode: i32, action: glfw.Action, mods: glfw.Mods) void {
            _ = scancode;
            _ = mods;
            if (action == .press) {
                switch (key) {
                    .space => window.setShouldClose(true),
                    else => {},
                }
            }
        }
    }.callback);
    try engine.core.internal.window.setSizeLimits(.{ .width = 20, .height = 20 }, .{ .width = null, .height = null });

    const vs_module = engine.gpu_driver.device.createShaderModule(&.{
        .label = "my vertex shader",
        .code = .{ .wgsl = @embedFile("vert.wgsl") },
    });

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    const fs_module = engine.gpu_driver.device.createShaderModule(&.{
        .label = "my fragment shader",
        .code = .{ .wgsl = @embedFile("frag.wgsl") },
    });

    const color_target = gpu.ColorTargetState{
        .format = engine.gpu_driver.swap_chain_format,
        .blend = null,
        .write_mask = gpu.ColorWriteMask.all,
    };
    const fragment = gpu.FragmentState{
        .module = fs_module,
        .entry_point = "main",
        .targets = &.{color_target},
        .constants = null,
    };

    const bgle = gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0);
    const bgl = engine.gpu_driver.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor{
            .entries = &.{bgle},
        },
    );

    const bind_group_layouts = [_]gpu.BindGroupLayout{bgl};
    const pipeline_layout = engine.gpu_driver.device.createPipelineLayout(&.{
        .bind_group_layouts = &bind_group_layouts,
    });

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .depth_stencil = null,
        .vertex = .{
            .module = vs_module,
            .entry_point = "main",
            .buffers = &.{vertex_buffer_layout},
        },
        .multisample = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alpha_to_coverage_enabled = false,
        },
        .primitive = .{
            .front_face = .ccw,
            .cull_mode = .back,
            .topology = .triangle_list,
            .strip_index_format = .none,
        },
    };

    const vertex_buffer = engine.gpu_driver.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = true,
    });
    var vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    std.mem.copy(Vertex, vertex_mapped, vertices[0..]);
    vertex_buffer.unmap();

    const x_count = 4;
    const y_count = 4;
    const num_instances = x_count * y_count;

    const uniform_buffer = engine.gpu_driver.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject) * num_instances,
        .mapped_at_creation = false,
    });
    defer uniform_buffer.release();
    const bind_group = engine.gpu_driver.device.createBindGroup(
        &gpu.BindGroup.Descriptor{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject) * num_instances),
            },
        },
    );

    app.pipeline = engine.gpu_driver.device.createRenderPipeline(&pipeline_descriptor);
    app.queue = engine.gpu_driver.device.getQueue();
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;

    vs_module.release();
    fs_module.release();
    pipeline_layout.release();
    bgl.release();
}

pub fn deinit(app: *App, _: *mach.Engine) void {
    app.vertex_buffer.release();
    app.bind_group.release();
}

var i: u32 = 0;

pub fn update(app: *App, engine: *mach.Engine) !bool {
    i += 1;

    const back_buffer_view = engine.gpu_driver.swap_chain.?.getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .resolve_target = null,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = engine.gpu_driver.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassEncoder.Descriptor{
        .color_attachments = &.{color_attachment},
    };

    {
        const proj = zm.perspectiveFovRh(
            (std.math.pi / 3.0),
            @intToFloat(f32, engine.gpu_driver.current_desc.width) / @intToFloat(f32, engine.gpu_driver.current_desc.height),
            10,
            30,
        );

        var ubos: [16]UniformBufferObject = undefined;
        const time = @intToFloat(f32, timer.read()) / @as(f32, std.time.ns_per_s);
        const step: f32 = 4.0;
        var m: u8 = 0;
        var x: u8 = 0;
        while (x < 4) : (x += 1) {
            var y: u8 = 0;
            while (y < 4) : (y += 1) {
                const trans = zm.translation(step * (@intToFloat(f32, x) - 2.0 + 0.5), step * (@intToFloat(f32, y) - 2.0 + 0.5), -20);
                const localTime = time + @intToFloat(f32, m) * 0.5;
                const model = zm.mul(zm.mul(zm.mul(zm.rotationX(localTime * (std.math.pi / 2.1)), zm.rotationY(localTime * (std.math.pi / 0.9))), zm.rotationZ(localTime * (std.math.pi / 1.3))), trans);
                const mvp = zm.mul(model, proj);
                const ubo = UniformBufferObject{
                    .mat = mvp,
                };
                ubos[m] = ubo;
                m += 1;
            }
        }
        encoder.writeBuffer(app.uniform_buffer, 0, UniformBufferObject, &ubos);
    }

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.draw(vertices.len, 16, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    app.queue.submit(&.{command});
    command.release();
    engine.gpu_driver.swap_chain.?.present();
    back_buffer_view.release();

    return true;
}