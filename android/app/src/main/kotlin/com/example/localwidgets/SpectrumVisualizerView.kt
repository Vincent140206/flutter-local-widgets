package com.example.localwidgets

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import android.view.animation.LinearInterpolator
import kotlin.math.abs
import kotlin.math.sin

class SpectrumVisualizerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : View(context, attrs, defStyleAttr) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF8E7DFF.toInt()
        strokeCap = Paint.Cap.ROUND
    }
    private var phase = 0f
    private var animator: ValueAnimator? = null

    fun setPlaying(playing: Boolean) {
        if (playing && animator == null) start() else if (!playing) stop()
    }

    private fun start() {
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 720L
            repeatCount = ValueAnimator.INFINITE
            interpolator = LinearInterpolator()
            addUpdateListener {
                phase = it.animatedFraction
                invalidate()
            }
            start()
        }
    }

    private fun stop() {
        animator?.cancel()
        animator = null
        phase = 0f
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (width == 0 || height == 0) return
        val bars = 5
        val gap = width * 0.075f
        val barWidth = (width - gap * (bars - 1)) / bars
        val radius = barWidth / 2f
        for (index in 0 until bars) {
            val wave = abs(sin((phase * Math.PI * 2.0) + index * 1.18)).toFloat()
            val secondary = abs(sin((phase * Math.PI * 3.0) - index * 0.72)).toFloat()
            val amplitude = 0.24f + (wave * 0.52f) + (secondary * 0.24f)
            val barHeight = (height * amplitude).coerceIn(barWidth, height.toFloat())
            val left = index * (barWidth + gap)
            val top = (height - barHeight) / 2f
            paint.alpha = 170 + index * 17
            canvas.drawRoundRect(left, top, left + barWidth, top + barHeight, radius, radius, paint)
        }
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }
}
