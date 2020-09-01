// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

namespace Microsoft.Quantum.Preparation {
    open Microsoft.Quantum.Intrinsic;
    open Microsoft.Quantum.Canon;
    open Microsoft.Quantum.Arithmetic;
    open Microsoft.Quantum.Convert;
    open Microsoft.Quantum.Math;
    open Microsoft.Quantum.Arrays;

    /// # Summary
    /// Uses the Quantum ROM technique to represent a given density matrix.
    ///
    /// Given a list of $N$ coefficients $\alpha_j$, this returns a unitary $U$ that uses the Quantum-ROM
    /// technique to prepare
    /// an approximation  $\tilde\rho\sum_{j=0}^{N-1}p_j\ket{j}\bra{j}$ of the purification of the density matrix
    /// $\rho=\sum_{j=0}^{N-1}\frac{|alpha_j|}{\sum_k |\alpha_k|}\ket{j}\bra{j}$. In this approximation, the
    /// error $\epsilon$ is such that $|p_j-\frac{|alpha_j|}{\sum_k |\alpha_k|}|\le \epsilon / N$ and
    /// $\|\tilde\rho - \rho\| \le \epsilon$. In other words,
    /// $$
    /// \begin{align}
    /// U\ket{0}^{\lceil\log_2 N\rceil}\ket{0}^{m}=\sum_{j=0}^{N-1}\sqrt{p_j} \ket{j}\ket{\text{garbage}_j}.
    /// \end{align}
    /// $$
    ///
    /// # Input
    /// ## targetError
    /// The target error $\epsilon$.
    /// ## coefficients
    /// Array of $N$ coefficients specifying the probability of basis states.
    /// Negative numbers $-\alpha_j$ will be treated as positive $|\alpha_j|$.
    ///
    /// # Output
    /// ## First parameter
    /// A tuple `(x,(y,z))` where `x = y + z` is the total number of qubits allocated,
    /// `y` is the number of qubits for the `LittleEndian` register, and `z` is the Number
    /// of garbage qubits.
    /// ## Second parameter
    /// The one-norm $\sum_j |\alpha_j|$ of the coefficient array.
    /// ## Third parameter
    /// The unitary $U$.
    ///
    /// # Remarks
    /// ## Example
    /// The following code snippet prepares an purification of the $3$-qubit state
    /// $\rho=\sum_{j=0}^{4}\frac{|alpha_j|}{\sum_k |\alpha_k|}\ket{j}\bra{j}$, where
    /// $\vec\alpha=(1.0,2.0,3.0,4.0,5.0)$, and the error is `1e-3`;
    /// ```qsharp
    /// let coefficients = [1.0,2.0,3.0,4.0,5.0];
    /// let targetError = 1e-3;
    /// let ((nTotalQubits, (nIndexQubits, nGarbageQubits)), oneNorm, op) = QuantumROM(targetError, coefficients);
    /// using (indexRegister = Qubit[nIndexQubits]) {
    ///     using (garbageRegister = Qubit[nGarbageQubits]) {
    ///         op(LittleEndian(indexRegister), garbageRegister);
    ///     }
    /// }
    /// ```
    ///
    /// # References
    /// - Encoding Electronic Spectra in Quantum Circuits with Linear T Complexity
    ///   Ryan Babbush, Craig Gidney, Dominic W. Berry, Nathan Wiebe, Jarrod McClean, Alexandru Paler, Austin Fowler, Hartmut Neven
    ///   https://arxiv.org/abs/1805.03662
    function QuantumROM(targetError: Double, coefficients: Double[])
    : ((Int, (Int, Int)), Double, ((LittleEndian, Qubit[]) => Unit is Adj + Ctl)) {
        let nBitsPrecision = -Ceiling(Lg(0.5 * targetError)) + 1;
        let positiveCoefficients = Mapped(AbsD, coefficients);
        let (oneNorm, keepCoeff, altIndex) = _QuantumROMDiscretization(nBitsPrecision, positiveCoefficients);
        let nCoeffs = Length(positiveCoefficients);
        let nBitsIndices = Ceiling(Lg(IntAsDouble(nCoeffs)));

        let op = PrepareQuantumROMStateWithoutSign(nBitsPrecision, nCoeffs, nBitsIndices, keepCoeff, altIndex, _, _);
        let qubitCounts = QuantumROMQubitCount(targetError, nCoeffs, false);
        return (qubitCounts, oneNorm, op);
    }

    internal function SplitSign(coefficient : Double) : (Double, Bool) {
        return (AbsD(coefficient), coefficient < 0.0);
    }

    function QuantumROMWithSign(targetError : Double, coefficients : Double[])
    : ((Int, (Int, Int)), Double, ((LittleEndian, Qubit, Qubit[]) => Unit is Adj + Ctl)) {
        let nBitsPrecision = -Ceiling(Lg(0.5 * targetError)) + 1;
        let (positiveCoefficients, signs) = Unzipped(Mapped(SplitSign, coefficients));
        let (oneNorm, keepCoeff, altIndex) = _QuantumROMDiscretization(nBitsPrecision, positiveCoefficients);
        let nCoeffs = Length(positiveCoefficients);
        let nBitsIndices = Ceiling(Lg(IntAsDouble(nCoeffs)));

        let op = PrepareQuantumROMStateWithSign(nBitsPrecision, nCoeffs, nBitsIndices, keepCoeff, altIndex, signs, _, _, _);
        let qubitCounts = QuantumROMQubitCount(targetError, nCoeffs, true);
        return (qubitCounts, oneNorm, op);
    }

    /// # Summary
    /// Returns the total number of qubits that must be allocated
    /// to the operation returned by `QuantumROM`.
    ///
    /// # Input
    /// ## targetError
    /// The target error $\epsilon$.
    /// ## nCoeffs
    /// Number of coefficients specified in `QuantumROM`.
    ///
    /// # Output
    /// ## First parameter
    /// A tuple `(x,(y,z))` where `x = y + z` is the total number of qubits allocated,
    /// `y` is the number of qubits for the `LittleEndian` register, and `z` is the Number
    /// of garbage qubits.
    function QuantumROMQubitCount(targetError: Double, nCoeffs: Int, hasSign : Bool)
    : (Int, (Int, Int)) {
        let nBitsPrecision = -Ceiling(Lg(0.5*targetError))+1;
        let nBitsIndices = Ceiling(Lg(IntAsDouble(nCoeffs)));
        let nGarbageQubits = nBitsIndices + 2 * nBitsPrecision + 1 + (hasSign ? 1 | 0);
        let nTotal = nGarbageQubits + nBitsIndices;
        return (nTotal, (nBitsIndices, nGarbageQubits));
    }

    // Classical processing
    // This discretizes the coefficients such that
    // |coefficient[i] * oneNorm - discretizedCoefficient[i] * discretizedOneNorm| * nCoeffs <= 2^{1-bitsPrecision}.
    function _QuantumROMDiscretization(bitsPrecision: Int, coefficients: Double[])
    : (Double, Int[], Int[]) {
        let oneNorm = PNorm(1.0, coefficients);
        let nCoefficients = Length(coefficients);
        if (bitsPrecision > 31) {
            fail $"Bits of precision {bitsPrecision} unsupported. Max is 31.";
        }
        if (nCoefficients <= 1) {
            fail "Cannot prepare state with less than 2 coefficients.";
        }
        if (oneNorm == 0.0) {
            fail "State must have at least one coefficient > 0";
        }

        let barHeight = 2^bitsPrecision - 1;

        mutable altIndex = RangeAsIntArray(0..nCoefficients - 1);
        mutable keepCoeff = Mapped(RoundedDiscretizationCoefficients(_, oneNorm, nCoefficients, barHeight), coefficients);

        // Calculate difference between number of discretized bars vs. maximum
        mutable bars = 0;
        for (idxCoeff in IndexRange(keepCoeff)) {
            set bars += keepCoeff[idxCoeff] - barHeight;
        }

        // Uniformly distribute excess bars across coefficients.
        for (idx in 0..AbsI(bars) - 1) {
            if (bars > 0) {
                set keepCoeff w/= idx <- keepCoeff[idx] - 1;
            } else {
                set keepCoeff w/= idx <- keepCoeff[idx] + 1;
            }
        }

        mutable barSink = new Int[nCoefficients];
        mutable barSource = new Int[nCoefficients];
        mutable nBarSink = 0;
        mutable nBarSource = 0;

        for (idxCoeff in IndexRange(keepCoeff)) {
            if (keepCoeff[idxCoeff] > barHeight) {
                set barSource w/= nBarSource <- idxCoeff;
                set nBarSource = nBarSource + 1;
            } elif (keepCoeff[idxCoeff] < barHeight) {
                set barSink w/= nBarSink <- idxCoeff;
                set nBarSink = nBarSink + 1;
            }
        }

        for (rep in 0..nCoefficients * 10) {
            if (nBarSource > 0 and nBarSink > 0) {
                let idxSink = barSink[nBarSink - 1];
                let idxSource = barSource[nBarSource - 1];
                set nBarSink = nBarSink - 1;
                set nBarSource = nBarSource - 1;

                set keepCoeff w/= idxSource <- keepCoeff[idxSource] - barHeight + keepCoeff[idxSink];
                set altIndex w/= idxSink <- idxSource;

                if (keepCoeff[idxSource] < barHeight) {
                    set barSink w/= nBarSink <- idxSource;
                    set nBarSink = nBarSink + 1;
                } elif(keepCoeff[idxSource] > barHeight) {
                    set barSource w/= nBarSource <- idxSource;
                    set nBarSource = nBarSource + 1;
                }
            }
            elif (nBarSource > 0) {
                let idxSource = barSource[nBarSource - 1];
                set nBarSource = nBarSource - 1;
                set keepCoeff w/= idxSource <- barHeight;
            } else {
                return (oneNorm, keepCoeff, altIndex);
            }
        }

        return (oneNorm, keepCoeff, altIndex);
    }

    // Used in QuantumROM implementation.
    internal function RoundedDiscretizationCoefficients(coefficient: Double, oneNorm: Double, nCoefficients: Int, barHeight: Int)
    : Int {
        return Round((AbsD(coefficient) / oneNorm) * IntAsDouble(nCoefficients) * IntAsDouble(barHeight));
    }

    // Used in QuantumROM implementation.
    internal operation PrepareQuantumROMState(nBitsPrecision: Int, nCoeffs: Int, nBitsIndices: Int, keepCoeff: Int[], altIndex: Int[], signs : Bool[], indexRegister: LittleEndian, signQubit : Qubit[], garbageRegister: Qubit[])
    : Unit is Adj + Ctl {
        let garbageIdx0 = nBitsIndices;
        let garbageIdx1 = garbageIdx0 + nBitsPrecision;
        let garbageIdx2 = garbageIdx1 + nBitsPrecision;
        let garbageIdx3 = garbageIdx2 + 1;

        let altIndexRegister = LittleEndian(garbageRegister[0..garbageIdx0 - 1]);
        let keepCoeffRegister = LittleEndian(garbageRegister[garbageIdx0..garbageIdx1 - 1]);
        let uniformKeepCoeffRegister = LittleEndian(garbageRegister[garbageIdx1..garbageIdx2 - 1]);
        let flagQubit = garbageRegister[garbageIdx3 - 1];

        // Create uniform superposition over index and alt coeff register.
        PrepareUniformSuperposition(nCoeffs, indexRegister);
        ApplyToEachCA(H, uniformKeepCoeffRegister!);

        // Write bitstrings to altIndex and keepCoeff register.
        if (Length(signs) == 0) {
            let unitaryGenerator = (nCoeffs, QuantumROMBitStringWriterByIndex(_, keepCoeff, altIndex));
            MultiplexOperationsFromGenerator(unitaryGenerator, indexRegister, (keepCoeffRegister, altIndexRegister));
        } else {
            let unitaryGenerator = (nCoeffs, QuantumROMWithSignBitStringWriterByIndex(_, keepCoeff, altIndex, signs));
            let altSignQubit = garbageRegister[garbageIdx3];
            MultiplexOperationsFromGenerator(unitaryGenerator, indexRegister, (keepCoeffRegister, altIndexRegister, Head(signQubit), altSignQubit));
        }

        // Perform comparison
        CompareUsingRippleCarry(uniformKeepCoeffRegister, keepCoeffRegister, flagQubit);

        let indexRegisterSize = Length(indexRegister!);

        // Swap in register based on comparison
        ApplyToEachCA((Controlled SWAP)([flagQubit], _), Zip(indexRegister!, altIndexRegister!));

        if (Length(signs) > 0) {
            let altSignQubit = garbageRegister[garbageIdx3];
            (Controlled SWAP)([flagQubit], (Head(signQubit), altSignQubit));
        }
    }

    // # Remark
    // Application case for Maybe UDT
    internal operation PrepareQuantumROMStateWithoutSign(nBitsPrecision: Int, nCoeffs: Int, nBitsIndices: Int, keepCoeff: Int[], altIndex: Int[], indexRegister: LittleEndian, garbageRegister: Qubit[])
    : Unit is Adj + Ctl {
        PrepareQuantumROMState(nBitsPrecision, nCoeffs, nBitsIndices, keepCoeff, altIndex, new Bool[0], indexRegister, new Qubit[0], garbageRegister);
    }

    // # Remark
    // Application case for Maybe UDT
    internal operation PrepareQuantumROMStateWithSign(nBitsPrecision: Int, nCoeffs: Int, nBitsIndices: Int, keepCoeff: Int[], altIndex: Int[], signs : Bool[], indexRegister: LittleEndian, signQubit : Qubit, garbageRegister: Qubit[])
    : Unit is Adj + Ctl {
        PrepareQuantumROMState(nBitsPrecision, nCoeffs, nBitsIndices, keepCoeff, altIndex, signs, indexRegister, [signQubit], garbageRegister);
    }

    // Used in QuantumROM implementation.
    internal function QuantumROMBitStringWriterByIndex(idx : Int, keepCoeff : Int[], altIndex : Int[])
    : ((LittleEndian, LittleEndian) => Unit is Adj + Ctl) {
        return WriteQuantumROMBitString(idx, keepCoeff, altIndex, _, _);
    }

    // Used in QuantumROM implementation.
    internal operation WriteQuantumROMBitString(idx: Int, keepCoeff: Int[], altIndex: Int[], keepCoeffRegister: LittleEndian, altIndexRegister: LittleEndian)
    : Unit is Adj + Ctl {
        ApplyXorInPlace(keepCoeff[idx], keepCoeffRegister);
        ApplyXorInPlace(altIndex[idx], altIndexRegister);
    }

    // Used in QuantumROMWithSign implementation.
    internal function QuantumROMWithSignBitStringWriterByIndex(idx : Int, keepCoeff : Int[], altIndex : Int[], signs : Bool[])
    : ((LittleEndian, LittleEndian, Qubit, Qubit) => Unit is Adj + Ctl) {
        return WriteQuantumWithSignROMBitString(idx, keepCoeff, altIndex, signs, _, _, _, _);
    }

    // Used in QuantumROMWithSign implementation.
    internal operation WriteQuantumWithSignROMBitString(idx: Int, keepCoeff: Int[], altIndex: Int[], signs : Bool[], keepCoeffRegister: LittleEndian, altIndexRegister: LittleEndian, signQubit : Qubit, altSignQubit : Qubit)
    : Unit is Adj + Ctl {
        ApplyXorInPlace(keepCoeff[idx], keepCoeffRegister);
        ApplyXorInPlace(altIndex[idx], altIndexRegister);
        ApplyIfCA(X, signs[idx], signQubit);
        ApplyIfCA(X, signs[altIndex[idx]], altSignQubit);
    }

}
